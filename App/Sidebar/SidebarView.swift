// A repo tab's sidebar (panel 1): tabs Branches (Local, Remote, Worktrees, Submodules and Stashes cards, ahead/behind counts), Tags, and
// Pull requests & Issues (`PullRequestSections`: the GitHub lists, or the Connect card). Each section is its own collapsible card. A click
// selects a row at once and the graph jumps to its commit; a double-click checks it out (the single click never waits
// for it); a right-click opens the same menu as its badge in the graph. A branch the graph hides is dimmed, with an eye
// that shows it again; a pinned or soloed one has a pin or a scope. The Local and Remote cards' header menus hide stale
// branches or show all. The Remote card's header menu also adds a remote and renames, removes, re-points or mirrors one. The Worktrees card lists the repo's worktrees (branch or HEAD, a pencil
// when one has uncommitted changes); a double-click opens another one in a tab, its header menu adds or prunes. The
// Submodules card, only in a repo that has some, lists them with their state; its header menu updates or syncs them.
import HistqCore
import SwiftUI

/// A sidebar tab. The raw value is its `-HistqSelect sidebar:<value>` name and its timing detail.
enum SidebarTab: String, CaseIterable, Hashable, Sendable {
    case branches, tags, prs

    /// `-HistqSelect sidebar:<value>`: the raw value, or `pullRequests` / `pr` for `prs`.
    init?(selectValue: String) {
        switch selectValue.lowercased() {
        case "pullrequests", "pull-requests", "pr", "issues": self = .prs
        default: self.init(rawValue: selectValue.lowercased())
        }
    }

    var title: String {
        switch self {
        case .branches: "Branches"
        case .tags: "Tags"
        case .prs: "Pull requests & Issues"
        }
    }

    /// The picker's label, beside the icon.
    var shortTitle: String {
        switch self {
        case .branches: "Branches"
        case .tags: "Tags"
        case .prs: "PRs"
        }
    }

    var systemImage: String {
        switch self {
        case .branches: "lucide-git-branch"
        case .tags: "tag"
        case .prs: "arrow.triangle.pull"
        }
    }
}

/// A selectable sidebar row, by its short name (`main`, `origin/main`, `v1.0`).
enum SidebarItem: Hashable, Sendable {
    case local(String)
    case remote(String)
    case tag(String)

    /// The `select` line of the timing log: `branch main`, `branch origin/main`, `tag v1.0`.
    var timingDetail: String {
        switch self {
        case .local(let name), .remote(let name): "branch \(name)"
        case .tag(let name): "tag \(name)"
        }
    }

    /// The full ref name, a tag's too (`refName` is a branch's only): `refs/heads/main`, `refs/remotes/origin/main`,
    /// `refs/tags/v1.0`.
    var fullRefName: String {
        switch self {
        case .local(let name): "refs/heads/\(name)"
        case .remote(let name): "refs/remotes/\(name)"
        case .tag(let name): "refs/tags/\(name)"
        }
    }
}

/// Sizes of the sidebar (the PRs tab's rows use them too).
enum SidebarMetrics {
    /// Between two section cards, and above the first one.
    static let cardSpacing = SectionCardMetrics.spacing
    /// Inside a section card, around its rows.
    static let cardPadding: CGFloat = 6
    /// Between two rows' capsules: tighter than Settings', the lists are long.
    static let rowSpacing: CGFloat = 2
    /// A row's icon from its capsule's leading edge. The card header's icon starts after its padding (10), the chevron
    /// (12) and a gap (6), 28 pt into the card; a row starts at the card padding (6) plus this, so the rows' icons
    /// line up with the section's own icon.
    static let rowLeading: CGFloat = 28 - cardPadding
    /// Of `rowLeading`, the part inside a selectable row's capsule, before its icon: the rest (and a nested row's
    /// indent) lies outside, so the hover and selection capsules start where the row is indented, not at the card's
    /// edge.
    static let capsuleLeading: CGFloat = 10
    /// The "…" menu buttons in the section headers: their label's square, so the hover circle (5 pt around it) is
    /// 24 pt, as big as the tab row's New Tab and tab list buttons (`TabStripMetrics.buttonHeight`).
    static let menuIconSide: CGFloat = TabStripMetrics.buttonHeight - 10
    /// A row's icon slot (glyphs leading-aligned in it, under the section's icon) and the gap from it to the name:
    /// tight, so the name sits close to a narrow branch glyph (user, 2026-11-13).
    static let iconSlot: CGFloat = 20
    static let iconGap: CGFloat = 4
    /// The extra indent of a remote's branches under the remote's row: one step.
    static let nestedIndent: CGFloat = 16
    /// The section and row icons: Local is this Mac, Remote the cloud, each branch a branch.
    static let localImage = "lucide-laptop-minimal"
    static let remoteImage = "cloud"
    /// The checked-out branch and the current worktree: a filled check in place of their own glyph.
    static let currentImage = "checkmark.circle.fill"
    static let branchImage = "lucide-git-branch"
    /// The Worktrees card and each worktree's row: a folder.
    static let worktreeImage = "folder"
    /// The Submodules card and each submodule's row: a box.
    static let submoduleImage = "shippingbox"
    /// The Stashes card and each stash's row: the tray of the graph's stash node.
    static let stashImage = "tray"

    /// A row's height at the text size: `SidebarItemStyle.height` (28) unless a line of text and 5 pt above and below
    /// need more. Not `SidebarItemStyle.height` itself, which the Settings sidebar shares.
    static func rowHeight(_ textSize: TextSize) -> CGFloat {
        max(SidebarItemStyle.height, textSize.lineHeight + 10)
    }
}

/// The sidebar of a repo tab: the tab picker across its width (icon and short name; the full name is the tooltip),
/// then its sections as cards in the panel's container: the expanded cards share its height and scroll inside (the PRs
/// tab's cards scroll together). The cards wait for the refs (capsule skeleton
/// rows in the same cards until then); the tab capsules and the cards' chevrons work at once.
struct SidebarView: View {
    @Bindable var session: RepoSession
    @AppStorage(PrefKey.sidebarSectionOrder.rawValue, store: Preferences.defaults) private var sectionOrder = ""
    @AppStorage(PrefKey.hiddenSidebarSections.rawValue, store: Preferences.defaults) private var hiddenSections = ""
    @Environment(\.textSize) private var textSize

    /// The sections the user shows, in their order (`SidebarSections`).
    private var layout: SidebarSections { SidebarSections(order: sectionOrder, hidden: hiddenSections) }
    /// The session's tab, or Branches while that one is hidden.
    private var tab: SidebarTab { layout.shownTab(session.sidebarTab) }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            CapsuleTabs(
                selection: Binding(get: { tab }, set: { session.selectSidebarTab($0) }),
                tabs: layout.tabs,
                title: { Text($0.shortTitle) },
                compact: true,
                help: \.title,
                fillsWidth: true,
                systemImage: \.systemImage)
            if tab == .prs {
                ScrollView {
                    cards
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
            } else {
                // As the WIP panel's cards: the expanded cards share the sidebar's height and scroll inside; the
                // collapsed ones keep their header.
                cards
                    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
            }
        }
    }

    private var cards: some View {
        VStack(alignment: .leading, spacing: SidebarMetrics.cardSpacing) {
            sections
        }
        // The panel's container pads the bottom.
        .padding(.top, SidebarMetrics.cardSpacing)
    }

    @ViewBuilder
    private var sections: some View {
        let branchIDs = layout.ids(in: .branches)
        switch (tab, session.refs) {
        case (.prs, _):
            PullRequestSections(session: session)
        // A Submodules card in a repo without any shows nothing, so it counts as hidden (not while still reading).
        case (.branches, _) where branchIDs.allSatisfy({ $0 == .submodules })
            && (branchIDs.isEmpty || session.submodules.value?.isEmpty == true):
            HiddenSectionsCard()
        case (.branches, .loaded(let refs)):
            BranchSections(session: session, refs: refs, ids: branchIDs)
                .onAppear { UITiming.content("sidebar \(session.url.lastPathComponent)") }
        case (.tags, .loaded(let refs)):
            let hidden = refs.tags.count { session.isHidden($0.refName) }
            SidebarSection(title: "Tags", systemImage: "tag",
                           count: refs.tags.count - (session.tagsShowHidden ? 0 : hidden),
                           isExpanded: $session.tagsExpanded) { query in
                TagRows(session: session, tags: refs.tags, query: query)
            } accessory: {
                HiddenRowsToggle(title: "Tags", count: hidden, isShowing: $session.tagsShowHidden)
            }
            .onAppear { UITiming.content("sidebar \(session.url.lastPathComponent)") }
        case (.branches, .idle), (.branches, .loading):
            ForEach(branchIDs, id: \.self) { id in
                switch id {
                case .local:
                    SidebarSection(title: "Local", systemImage: SidebarMetrics.localImage, count: nil,
                                   isExpanded: $session.localExpanded) { _ in
                        SkeletonRows(fractions: [0.45, 0.6, 0.35, 0.7, 0.5])
                    }
                case .remote:
                    SidebarSection(title: "Remote", systemImage: SidebarMetrics.remoteImage, count: nil,
                                   isExpanded: $session.remoteExpanded) { _ in
                        SkeletonRows(fractions: [0.3, 0.55, 0.4])
                    }
                case .worktrees:
                    SidebarSection(title: "Worktrees", systemImage: SidebarMetrics.worktreeImage, count: nil,
                                   isExpanded: $session.worktreesExpanded) { _ in
                        SkeletonRows(fractions: [0.4, 0.55])
                    }
                case .submodules:
                    // Read after the graph's first page, and only shown when the repo has some.
                    EmptyView()
                default:
                    EmptyView()
                }
            }
            SidebarSection(title: "Stashes", systemImage: SidebarMetrics.stashImage, count: nil,
                           isExpanded: $session.stashesExpanded) { _ in
                SkeletonRows(fractions: [0.5, 0.35])
            }
        case (.tags, .idle), (.tags, .loading):
            SidebarSection(title: "Tags", systemImage: "tag", count: nil, isExpanded: $session.tagsExpanded) { _ in
                SkeletonRows(fractions: [0.3, 0.45, 0.35, 0.5])
            }
        case (_, .failed(let message)):
            Label(message, systemImage: "exclamationmark.triangle")
                .font(textSize.body)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
                .padding(SidebarMetrics.cardPadding + 4)
                .frame(maxWidth: .infinity, alignment: .leading)
                .modifier(GlassCard(cornerRadius: SettingsMetrics.cardRadius))
        }
    }
}

/// The Local, Remote, Worktrees and Submodules cards, those of `ids` in its order. Remote branches are grouped by
/// remote inside their card.
private struct BranchSections: View {
    @Bindable var session: RepoSession
    let refs: Refs
    /// The Branches tab's visible sections (`SidebarSections`), in order.
    let ids: [SidebarSectionID]

    var body: some View {
        ForEach(ids, id: \.self) { id in
            switch id {
            case .local: localCard
            case .remote: remoteCard
            case .worktrees: WorktreeSection(session: session)
            case .submodules: SubmoduleSection(session: session)
            default: EmptyView()
            }
        }
        StashSection(session: session)
    }

    // The headers count the listed rows: the hidden ones only while their card lists them.
    private var localCard: some View {
        let hiddenLocal = refs.localBranches.count { session.isHidden($0.refName) }
        return SidebarSection(title: "Local", systemImage: SidebarMetrics.localImage,
                       count: refs.localBranches.count - (session.localShowsHidden ? 0 : hiddenLocal),
                       isExpanded: $session.localExpanded) { query in
            let listed = refs.localBranches.filter { session.localShowsHidden || !session.isHidden($0.refName) }
            let branches = listed.filter { FileSearch.matches($0.name, query: query) }
            if refs.localBranches.isEmpty {
                EmptyRow(text: "No local branches")
            } else if listed.isEmpty {
                EmptyRow(text: "All branches are hidden")
            } else if branches.isEmpty {
                EmptyRow(text: "No matching branches")
            }
            ForEach(branches, id: \.refName) { branch in
                // The checked-out branch shows a check in place of the branch icon.
                BranchRow(session: session, item: .local(branch.name), name: branch.name,
                          systemImage: branch.isHead ? SidebarMetrics.currentImage : SidebarMetrics.branchImage) {
                    AheadBehind(branch: branch)
                }
            }
        } accessory: {
            HiddenRowsToggle(title: "Local", count: hiddenLocal, isShowing: $session.localShowsHidden)
            Menu {
                MenuEntriesView(entries: RepoMenus.branchView(session))
            } label: {
                Image(systemName: "ellipsis")
                    .foregroundStyle(.secondary)
                    // Square, so the hover circle (sized on the label's shorter side) clears the wide glyph.
                    .frame(width: SidebarMetrics.menuIconSide, height: SidebarMetrics.menuIconSide)
            }
            .menuStyle(.button)
            .buttonStyle(RowIconButtonStyle())
            .menuIndicator(.hidden)
            .fixedSize()
            .help("Local branches")
            .accessibilityLabel("Local branch actions")
        }
    }

    private var remoteCard: some View {
        let hiddenRemote = refs.remoteBranches.count { session.isHidden($0.refName) }
        return SidebarSection(title: "Remote", systemImage: SidebarMetrics.remoteImage,
                       count: refs.remoteBranches.count - (session.remoteShowsHidden ? 0 : hiddenRemote),
                       isExpanded: $session.remoteExpanded) { query in
            let shown = filteredRemotes(query)
            if remotes.isEmpty {
                EmptyRow(text: "No remotes")
            } else if shown.isEmpty {
                EmptyRow(text: "No matching branches")
            }
            ForEach(shown, id: \.name) { remote in
                RemoteRow(name: remote.name, url: session.remotes.first { $0.name == remote.name }?.url)
                    .contextMenu { MenuEntriesView(entries: RepoMenus.remote(named: remote.name, session)) }
                ForEach(remote.branches, id: \.refName) { branch in
                    BranchRow(session: session, item: .remote(branch.name),
                              name: String(branch.name.dropFirst(remote.name.count + 1)),
                              systemImage: SidebarMetrics.branchImage, indent: SidebarMetrics.nestedIndent) {
                        EmptyView()
                    }
                }
            }
        } accessory: {
            HiddenRowsToggle(title: "Remote", count: hiddenRemote, isShowing: $session.remoteShowsHidden)
            Menu {
                MenuEntriesView(entries: RepoMenus.remotes(session) + [.separator] + RepoMenus.branchView(session))
            } label: {
                Image(systemName: "ellipsis")
                    .foregroundStyle(.secondary)
                    // Square, so the hover circle (sized on the label's shorter side) clears the wide glyph.
                    .frame(width: SidebarMetrics.menuIconSide, height: SidebarMetrics.menuIconSide)
            }
            .menuStyle(.button)
            .buttonStyle(RowIconButtonStyle())
            .menuIndicator(.hidden)
            .fixedSize()
            .help("Remotes")
            .accessibilityLabel("Remote actions")
        }
    }

    /// Remote branches by remote: the remotes in git's order (also those with no fetched branch), then any other remote
    /// a branch names.
    private var remotes: [(name: String, branches: [RemoteBranch])] {
        var order: [String] = session.remotes.map(\.name)
        var groups: [String: [RemoteBranch]] = Dictionary(order.map { ($0, []) }, uniquingKeysWith: { a, _ in a })
        for branch in refs.remoteBranches {
            if groups[branch.remote] == nil { order.append(branch.remote) }
            guard session.remoteShowsHidden || !session.isHidden(branch.refName) else { continue }
            groups[branch.remote, default: []].append(branch)
        }
        return order.map { ($0, groups[$0] ?? []) }
    }

    /// The remotes whose name or a branch's full name (`origin/main`) matches `query`, with only their matching
    /// branches; all of them with an empty query.
    private func filteredRemotes(_ query: String) -> [(name: String, branches: [RemoteBranch])] {
        guard !query.isEmpty else { return remotes }
        return remotes.compactMap { remote in
            let branches = remote.branches.filter { FileSearch.matches($0.name, query: query) }
            guard !branches.isEmpty || FileSearch.matches(remote.name, query: query) else { return nil }
            return (remote.name, branches)
        }
    }
}

/// The Branches tab with Local, Remote, Worktrees and Submodules all hidden: says so, with the button to Settings ›
/// Appearance.
private struct HiddenSectionsCard: View {
    @Environment(WindowModel.self) private var model
    @Environment(\.textSize) private var textSize

    var body: some View {
        SectionCard("Branches", systemImage: SidebarTab.branches.systemImage) {
            VStack(alignment: .leading, spacing: 8) {
                Text("All sections are hidden")
                    .font(textSize.bodyMedium)
                Text("Local, Remote, Worktrees and Submodules are hidden in Settings › Appearance.")
                    .font(textSize.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                Button("Show Sections…") { model.selectSettings(.appearance) }
                    .buttonStyle(RowTextButtonStyle(prominent: true))
                    .help("Settings › Appearance")
            }
        }
    }
}

/// The Worktrees card: its rows once the worktrees are read (after the graph's first page, so skeleton rows until
/// then), and the header's menu (Add Worktree, Prune).
private struct WorktreeSection: View {
    @Bindable var session: RepoSession

    var body: some View {
        SidebarSection(title: "Worktrees", systemImage: SidebarMetrics.worktreeImage, count: count,
                       isExpanded: $session.worktreesExpanded) { query in
            switch session.worktrees {
            case .idle, .loading:
                SkeletonRows(fractions: [0.4, 0.55])
            case .loaded(let worktrees):
                // By its folder name or its branch.
                let shown = worktrees.filter { FileSearch.matches("\($0.name) \($0.headLabel)", query: query) }
                if shown.isEmpty, !worktrees.isEmpty { EmptyRow(text: "No matching worktrees") }
                ForEach(shown, id: \.path) { info in
                    WorktreeRow(session: session, info: info)
                }
            case .failed(let message):
                EmptyRow(text: message)
            }
        } accessory: {
            Menu {
                MenuEntriesView(entries: RepoMenus.worktrees(session))
            } label: {
                Image(systemName: "ellipsis")
                    .foregroundStyle(.secondary)
                    // Square, so the hover circle (sized on the label's shorter side) clears the wide glyph.
                    .frame(width: SidebarMetrics.menuIconSide, height: SidebarMetrics.menuIconSide)
            }
            .menuStyle(.button)
            .buttonStyle(RowIconButtonStyle())
            .menuIndicator(.hidden)
            .fixedSize()
            .help("Worktrees")
            .accessibilityLabel("Worktree actions")
        }
    }

    /// Nil (a loading count) only while the worktrees load; a failed read shows its message, not a spinner.
    private var count: Int? {
        if case .failed = session.worktrees { return 0 }
        return session.worktrees.value?.count
    }
}

/// A worktree's row: a check for this tab's own (as the checked-out branch), a folder for the others; its folder name,
/// a pencil when it has uncommitted changes, then its branch or short HEAD. A click jumps the graph at once to its
/// changes' row when it has any (`selectWorktree`), else to its HEAD commit; a double-click opens another worktree in a
/// tab, recognized beside the single click (`simultaneousGesture`). Its context menu opens, removes or prunes.
private struct WorktreeRow: View {
    let session: RepoSession
    let info: WorktreeInfo
    @State private var hovered = false
    @Environment(\.textSize) private var textSize

    var body: some View {
        HStack(spacing: SidebarMetrics.iconGap) {
            Image(systemName: info.isCurrent ? SidebarMetrics.currentImage : SidebarMetrics.worktreeImage)
                .imageScale(info.isCurrent ? .large : .medium)
                .frame(width: SidebarMetrics.iconSlot, alignment: .leading)
            HStack(spacing: 4) {
                Text(info.name)
                    .font(textSize.body)
                    .lineLimit(1)
                    .truncationMode(.middle)
                Spacer(minLength: 4)
                if let changes {
                    Image(systemName: "pencil")
                        .foregroundStyle(Color(nsColor: Palette.graphLanes[0]))
                        .help("Uncommitted changes: \(changes)")
                }
                Text(info.worktree.isPrunable ? "missing" : info.headLabel)
                    .font(textSize.caption)
                    .lineLimit(1)
                    .truncationMode(.middle)
            }
        }
        .foregroundStyle(.secondary)
        .padding(.leading, SidebarMetrics.capsuleLeading)
        .padding(.trailing, 10)
        .frame(minHeight: SidebarMetrics.rowHeight(textSize))
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Capsule().fill(hovered ? Palette.hoverFill : .clear))
        .contentShape(Capsule())
        .padding(.leading, SidebarMetrics.rowLeading - SidebarMetrics.capsuleLeading)
        .animation(Motion.hover, value: hovered)
        .onHover { hovered = $0 }
        .onTapGesture { showHead() }
        .simultaneousGesture(TapGesture(count: 2).onEnded { open() })
        .contextMenu { MenuEntriesView(entries: RepoMenus.worktree(info.path, session)) }
        .help(info.path)
        .accessibilityElement(children: .combine)
        .accessibilityAddTraits(.isButton)
        .accessibilityLabel("Worktree \(info.name), \(info.headLabel)\(changes == nil ? "" : ", uncommitted changes")")
        .accessibilityAction { showHead() }
        .accessibilityAction(named: "Open in New Tab") { open() }
    }

    /// This tab's own changes come from its status, another worktree's from its own read.
    private var changes: String? {
        if info.isCurrent {
            guard let status = session.status.value, !status.entries.isEmpty else { return nil }
            return WorktreeChanges(status).detail
        }
        return info.isDirty ? info.changes?.detail : nil
    }

    private func showHead() {
        session.selectWorktree(info)
    }

    private func open() {
        guard !info.isCurrent, !info.worktree.isPrunable else { return }
        session.openWorktree(info.path)
    }
}

/// The Submodules card, only in a repo that has submodules (read after the graph's first page): its submodules in
/// index order, each nested one under its parent, and the header's menu (Update All, Sync All).
private struct SubmoduleSection: View {
    @Bindable var session: RepoSession

    var body: some View {
        switch session.submodules {
        case .loaded(let submodules) where !submodules.isEmpty:
            SidebarSection(title: "Submodules", systemImage: SidebarMetrics.submoduleImage, count: submodules.count,
                           isExpanded: $session.submodulesExpanded) { query in
                // By its name, its path or its branch.
                let shown = submodules.filter { FileSearch.matches("\($0.name) \($0.path) \(branch($0))", query: query) }
                if shown.isEmpty { EmptyRow(text: "No matching submodules") }
                ForEach(shown) { submodule in
                    SubmoduleRow(session: session, submodule: submodule,
                                 depth: submodules.count { submodule.path.hasPrefix($0.path + "/") })
                }
            } accessory: {
                Menu {
                    MenuEntriesView(entries: RepoMenus.submodules(session))
                } label: {
                    Image(systemName: "ellipsis")
                        .foregroundStyle(.secondary)
                        // Square, so the hover circle (sized on the label's shorter side) clears the wide glyph.
                        .frame(width: SidebarMetrics.menuIconSide, height: SidebarMetrics.menuIconSide)
                }
                .menuStyle(.button)
                .buttonStyle(RowIconButtonStyle())
                .menuIndicator(.hidden)
                .fixedSize()
                .help("Submodules")
                .accessibilityLabel("Submodule actions")
            }
        case .failed(let message):
            // The repo has a `.gitmodules` the read could not list.
            SidebarSection(title: "Submodules", systemImage: SidebarMetrics.submoduleImage, count: 0,
                           isExpanded: $session.submodulesExpanded) { _ in
                EmptyRow(text: message)
            }
        default:
            EmptyView()
        }
    }

    private func branch(_ submodule: Submodule) -> String {
        if case .checkedOut(_, let branch?) = submodule.state { branch } else { "" }
    }

}

/// A submodule's row: a box, its name (a nested one's path, indented under its parent), its state chips (not
/// initialized or not checked out; new commits when its checkout is off the recorded commit; its uncommitted changes;
/// its branch), then the recorded commit. A click selects it at once; a double-click, recognized beside the single
/// click (`simultaneousGesture`), opens it in a tab, or initializes and checks out a top-level one with no checkout.
private struct SubmoduleRow: View {
    let session: RepoSession
    let submodule: Submodule
    /// How many submodules it is nested in.
    let depth: Int
    @State private var hovered = false
    @Environment(\.textSize) private var textSize

    var body: some View {
        let selected = session.selection == .submodule(submodule.path)
        HStack(spacing: SidebarMetrics.iconGap) {
            Image(systemName: SidebarMetrics.submoduleImage)
                .frame(width: SidebarMetrics.iconSlot, alignment: .leading)
            HStack(spacing: 4) {
                Text(depth == 0 ? submodule.name : submodule.path)
                    .font(textSize.body)
                    .lineLimit(1)
                    .truncationMode(.middle)
                    // The name first; the chips and the commit take what is left.
                    .layoutPriority(1)
                Spacer(minLength: 4)
                // The chips and the recorded commit when they fit, else the commit goes, then whole chips, the branch
                // first (all of them are in the tooltip). The first chip always stays: the name truncates for it.
                ViewThatFits(in: .horizontal) {
                    HStack(spacing: 4) {
                        chipViews(chips)
                        Text(submodule.recordedCommit.prefix(7))
                            .font(textSize.caption)
                            .monospaced()
                            .lineLimit(1)
                            .fixedSize()
                    }
                    ForEach(Array(stride(from: chips.count, through: min(chips.count, 1), by: -1)), id: \.self) {
                        count in
                        HStack(spacing: 4) { chipViews(Array(chips.prefix(count))) }
                    }
                }
            }
        }
        .foregroundStyle(selected ? Color.primary : Color.secondary)
        .padding(.leading, SidebarMetrics.capsuleLeading)
        .padding(.trailing, 10)
        .frame(minHeight: SidebarMetrics.rowHeight(textSize))
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Capsule().fill(selected ? Palette.selectedFill : hovered ? Palette.hoverFill : .clear))
        .overlay(Capsule().strokeBorder(selected ? Palette.selectedBorder : .clear, lineWidth: 1))
        .contentShape(Capsule())
        .padding(.leading, SidebarMetrics.rowLeading - SidebarMetrics.capsuleLeading
                    + CGFloat(depth) * SidebarMetrics.nestedIndent)
        .animation(Motion.hover, value: hovered)
        .onHover { hovered = $0 }
        .onTapGesture { select() }
        .simultaneousGesture(TapGesture(count: 2).onEnded { open() })
        .contextMenu { MenuEntriesView(entries: RepoMenus.submodule(submodule.path, session)) }
        .help(([submodule.path, submodule.url, chips.isEmpty ? nil : chips.joined(separator: " · ")])
            .compactMap(\.self).joined(separator: "\n"))
        .accessibilityElement(children: .combine)
        .accessibilityAddTraits(selected ? [.isButton, .isSelected] : .isButton)
        .accessibilityLabel(([ "Submodule \(submodule.path)"] + chips).joined(separator: ", "))
        .accessibilityAction { select() }
        .accessibilityAction(named: "Open in New Tab") { open() }
    }

    private func chipViews(_ chips: [String]) -> some View {
        ForEach(chips, id: \.self) { chip in
            Text(chip)
                .font(textSize.caption)
                .lineLimit(1)
                .fixedSize()
                .padding(.horizontal, 6)
                .background(Capsule().fill(Palette.inputSurface))
        }
    }

    private var isCheckedOut: Bool {
        if case .checkedOut = submodule.state { true } else { false }
    }

    private var chips: [String] {
        var chips: [String] = []
        switch submodule.state {
        case .notInitialized: chips.append("Not initialized")
        case .notCheckedOut: chips.append("Not checked out")
        case .checkedOut: break
        }
        if submodule.isMoved { chips.append("New commits") }
        if submodule.changeCount > 0 {
            chips.append(submodule.changeCount == 1 ? "1 change" : "\(submodule.changeCount) changes")
        }
        if case .checkedOut(_, let branch?) = submodule.state { chips.append(branch) }
        return chips
    }

    private func select() {
        session.selectSubmodule(submodule.path)
    }

    private func open() {
        if isCheckedOut {
            session.openSubmodule(submodule.path)
        } else if depth == 0 {
            update()
        }
    }

    private func update() {
        let initialize = !isCheckedOut
        session.run(.updateSubmodules([submodule.path], initialize: initialize),
                    title: "\(initialize ? "Initialize" : "Update") submodule \(submodule.path)")
    }
}

/// The Stashes card, last in the Branches tab and collapsed by default: the repo's stashes, newest first, read with the
/// graph's log (skeleton rows until its first page).
private struct StashSection: View {
    @Bindable var session: RepoSession

    var body: some View {
        let stashes = session.log.value?.stashes
        SidebarSection(title: "Stashes", systemImage: SidebarMetrics.stashImage, count: stashes?.count,
                       isExpanded: $session.stashesExpanded) { query in
            if let stashes {
                let shown = stashes.filter { FileSearch.matches("\($0.selector) \($0.message)", query: query) }
                if stashes.isEmpty {
                    EmptyRow(text: "No stashes")
                } else if shown.isEmpty {
                    EmptyRow(text: "No matching stashes")
                }
                ForEach(shown) { stash in
                    StashRow(session: session, stash: stash)
                }
            } else {
                SkeletonRows(fractions: [0.5, 0.35])
            }
        }
    }
}

/// A stash's row: a tray, its message, then its `stash@{n}`. A click selects its row in the graph and shows its
/// detail at once; its context menu is the graph row's (Apply, Pop, Drop).
private struct StashRow: View {
    let session: RepoSession
    let stash: Stash
    @State private var hovered = false
    @Environment(\.textSize) private var textSize

    var body: some View {
        let selected = session.graphSelection == [.stash(stash.hash)]
        HStack(spacing: SidebarMetrics.iconGap) {
            Image(systemName: SidebarMetrics.stashImage)
                .frame(width: SidebarMetrics.iconSlot, alignment: .leading)
            HStack(spacing: 4) {
                Text(stash.message)
                    .font(textSize.body)
                    .lineLimit(1)
                    .truncationMode(.tail)
                Spacer(minLength: 4)
                Text(stash.selector)
                    .font(textSize.caption)
                    .lineLimit(1)
            }
        }
        .foregroundStyle(selected ? Color.primary : Color.secondary)
        .padding(.leading, SidebarMetrics.capsuleLeading)
        .padding(.trailing, 10)
        .frame(minHeight: SidebarMetrics.rowHeight(textSize))
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Capsule().fill(selected ? Palette.selectedFill : hovered ? Palette.hoverFill : .clear))
        .overlay(Capsule().strokeBorder(selected ? Palette.selectedBorder : .clear, lineWidth: 1))
        .contentShape(Capsule())
        .padding(.leading, SidebarMetrics.rowLeading - SidebarMetrics.capsuleLeading)
        .animation(Motion.hover, value: hovered)
        .onHover { hovered = $0 }
        .onTapGesture { select() }
        .contextMenu { MenuEntriesView(entries: RepoMenus.stash(stash.hash, session)) }
        .help("\(stash.selector): \(stash.message)")
        .accessibilityElement(children: .combine)
        .accessibilityAddTraits(selected ? [.isButton, .isSelected] : .isButton)
        .accessibilityLabel("Stash \(stash.selector), \(stash.message)")
        .accessibilityAction { select() }
    }

    /// A sidebar click shows the graph, in Stacked too (as `selectWorktree`).
    private func select() {
        session.selectGraph([.stash(stash.hash)], keepsPanel2: false)
    }
}

private struct TagRows: View {
    let session: RepoSession
    let tags: [TagRef]
    let query: String

    var body: some View {
        let listed = tags.filter { session.tagsShowHidden || !session.isHidden($0.refName) }
        let shown = listed.filter { FileSearch.matches($0.name, query: query) }
        if tags.isEmpty {
            EmptyRow(text: "No tags")
        } else if listed.isEmpty {
            EmptyRow(text: "All tags are hidden")
        } else if shown.isEmpty {
            EmptyRow(text: "No matching tags")
        }
        ForEach(shown, id: \.refName) { tag in
            BranchRow(session: session, item: .tag(tag.name), name: tag.name,
                      systemImage: tag.isAnnotated ? "tag.fill" : "tag") { EmptyView() }
        }
    }
}

/// A section of the sidebar in its own collapsible `SectionCard`: its rows, tightly stacked. `count` nil while the
/// refs load. `accessory` sits at the header's end (the Remote card's menu). Once loaded, the header's search button
/// opens a field above the rows, and `content` gets its query (empty while closed) to show the matching rows only.
private struct SidebarSection<Content: View, Accessory: View>: View {
    let title: String
    let systemImage: String
    let count: Int?
    @Binding var isExpanded: Bool
    @ViewBuilder let content: (_ query: String) -> Content
    @ViewBuilder let accessory: () -> Accessory
    @State private var isSearching = false
    @State private var query = ""

    var body: some View {
        SectionCard(title, systemImage: systemImage, count: count, countIsLoading: count == nil,
                    isExpanded: $isExpanded, contentPadding: SidebarMetrics.cardPadding) {
            VStack(alignment: .leading, spacing: 0) {
                if isSearching {
                    CardSearchField(prompt: "Filter by name", isSearching: $isSearching, query: $query)
                }
                // Its share of the sidebar's height, scrolling inside when the rows don't fit.
                CardScrollView {
                    VStack(alignment: .leading, spacing: SidebarMetrics.rowSpacing) {
                        content(isSearching ? query : "")
                    }
                }
                .frame(maxHeight: .infinity)
            }
        } accessory: {
            HStack(spacing: 10) {
                // Not while loading: the loaded card is another view, which would drop the open field.
                if count != nil {
                    CardSearchButton(title: title, isSearching: $isSearching, query: $query, isExpanded: $isExpanded)
                }
                accessory()
            }
        }
    }
}

extension SidebarSection where Accessory == EmptyView {
    init(title: String, systemImage: String, count: Int?, isExpanded: Binding<Bool>,
         @ViewBuilder content: @escaping (_ query: String) -> Content) {
        self.init(title: title, systemImage: systemImage, count: count, isExpanded: isExpanded, content: content,
                  accessory: { EmptyView() })
    }
}

/// A sidebar card's search button, at its header's end (in the accent color while open): opens the card's
/// `CardSearchField` (expanding a collapsed card), or closes it and clears the query.
struct CardSearchButton: View {
    let title: String
    @Binding var isSearching: Bool
    @Binding var query: String
    @Binding var isExpanded: Bool

    var body: some View {
        Button {
            if isSearching {
                isSearching = false
                query = ""
            } else {
                isSearching = true
                isExpanded = true
            }
        } label: {
            Image(systemName: "magnifyingglass")
                .foregroundStyle(isSearching ? AnyShapeStyle(Color.accentColor) : AnyShapeStyle(.secondary))
                // The "…" menus' square, so both hover circles are the same size.
                .frame(width: SidebarMetrics.menuIconSide, height: SidebarMetrics.menuIconSide)
        }
        .buttonStyle(RowIconButtonStyle())
        .help(isSearching ? "Close Search" : "Search \(title)")
        .accessibilityLabel(isSearching ? "Close search" : "Search \(title)")
    }
}

/// A card header's eye button while some of its rows are hidden (`RepoSession.isHidden`): lists them, dimmed, so their
/// eye or menu can show them again, or leaves them out again. The graph keeps them hidden either way.
private struct HiddenRowsToggle: View {
    let title: String
    let count: Int
    @Binding var isShowing: Bool

    var body: some View {
        if count > 0 {
            Button {
                isShowing.toggle()
            } label: {
                Image(systemName: isShowing ? "eye" : "eye.slash")
                    .foregroundStyle(isShowing ? AnyShapeStyle(Color.accentColor) : AnyShapeStyle(.secondary))
                    .frame(width: SidebarMetrics.menuIconSide, height: SidebarMetrics.menuIconSide)
            }
            .buttonStyle(RowIconButtonStyle())
            .help(isShowing ? "Leave Out Hidden \(title) Items" : "List \(count) Hidden \(title) Items")
            .accessibilityLabel(isShowing ? "Leave out hidden \(title) items" : "List \(count) hidden \(title) items")
        }
    }
}

/// A sidebar card's search field, above its rows: it takes the focus as it opens, and Escape closes it and clears
/// the query.
struct CardSearchField: View {
    let prompt: String
    @Binding var isSearching: Bool
    @Binding var query: String
    @FocusState private var focused: Bool

    var body: some View {
        TextField(prompt, text: $query, prompt: Text(prompt))
            .textFieldStyle(.settings)
            .labelsHidden()
            .focused($focused)
            // Next run-loop turn, once the field is in the window.
            .onAppear { DispatchQueue.main.async { focused = true } }
            .onKeyPress(.escape) {
                isSearching = false
                query = ""
                return .handled
            }
            .padding(.bottom, 6)
    }
}

/// The text of an empty section.
struct EmptyRow: View {
    let text: String
    @Environment(\.textSize) private var textSize

    var body: some View {
        Text(text)
            .font(textSize.body)
            .foregroundStyle(.secondary)
            .padding(.leading, SidebarMetrics.rowLeading)
            .padding(.trailing, 10)
            .frame(height: SidebarMetrics.rowHeight(textSize))
    }
}

/// A remote's row in the Remote card ("origin"): its owner's logo (in real avatar mode) or a server icon, and its
/// name, its branches indented under it. Its context menu renames, removes or re-points the remote.
private struct RemoteRow: View {
    let name: String
    /// The remote's URL; nil for a remote only fetched branches name.
    let url: String?
    @State private var ownerAvatar: NSImage?
    @Environment(\.displayScale) private var scale
    @Environment(\.textSize) private var textSize
    private static let avatarSide: CGFloat = 16

    var body: some View {
        HStack(spacing: SidebarMetrics.iconGap) {
            Group {
                if let ownerAvatar {
                    Image(nsImage: ownerAvatar)
                        .resizable()
                        .interpolation(.high)
                        .frame(width: Self.avatarSide, height: Self.avatarSide)
                        .clipShape(RoundedRectangle(cornerRadius: 3, style: .continuous))
                } else {
                    Image(systemName: "server.rack")
                }
            }
            .frame(width: SidebarMetrics.iconSlot, alignment: .leading)
            Text(name)
                .font(textSize.bodyMedium)
                .lineLimit(1)
                .truncationMode(.middle)
        }
        .foregroundStyle(.secondary)
        .padding(.leading, SidebarMetrics.rowLeading)
        .padding(.trailing, 10)
        .frame(minHeight: SidebarMetrics.rowHeight(textSize))
        .frame(maxWidth: .infinity, alignment: .leading)
        .contentShape(Rectangle())
        .help(name)
        .accessibilityElement(children: .combine)
        .accessibilityLabel("Remote \(name)")
        .onAppear(perform: loadAvatar)
        .onChange(of: url) { loadAvatar() }
        .onReceive(NotificationCenter.default.publisher(for: AvatarStore.didChange)) { note in
            // No identity: the avatar mode changed.
            let changed = note.userInfo?[AvatarStore.emailKey] as? String
            if changed == nil || changed == repository.map(AvatarStore.ownerIdentity) { loadAvatar() }
        }
    }

    private var repository: HostedRepository? {
        url.flatMap(GitHubClient.repository(fromRemoteURL:))
    }

    private func loadAvatar() {
        ownerAvatar = repository.flatMap {
            AvatarStore.shared.ownerAvatar(of: $0, pixels: Int((Self.avatarSide * scale).rounded(.up)))
        }
    }
}

/// A selectable row: icon, name (truncated in the middle), then `trailing` (the ahead/behind counts). A click selects
/// it and jumps the graph to its commit before anything loads; a double-click checks it out, recognized beside the
/// single click (`simultaneousGesture`), so the single click never waits for it. Its context menu is its badge's.
private struct BranchRow<Trailing: View>: View {
    let session: RepoSession
    let item: SidebarItem
    let name: String
    let systemImage: String
    /// Past `SidebarMetrics.rowLeading`: a remote's branches sit one step in from the remote's row.
    var indent: CGFloat = 0
    @ViewBuilder let trailing: () -> Trailing
    @State private var hovered = false
    @Environment(\.textSize) private var textSize

    var body: some View {
        let selected = session.sidebarSelection == item
        let ref = item.fullRefName
        // A ref the graph leaves out, listed only while its card shows the hidden rows: its icon and name dimmed, with
        // a slashed eye at the end that shows it again.
        let dimmed = session.isHidden(ref) ? 0.5 : 1.0
        HStack(spacing: SidebarMetrics.iconGap) {
            // Leading-aligned in its slot, so every glyph starts where the section header's icon does.
            IconImage(systemImage)
                // The checked-out branch's check reads at a glance (a step bigger than the branch glyphs).
                .imageScale(systemImage == SidebarMetrics.currentImage ? .large : .medium)
                .frame(width: SidebarMetrics.iconSlot, alignment: .leading)
                .opacity(dimmed)
            HStack(spacing: 4) {
                Text(name)
                    .font(textSize.body)
                    .lineLimit(1)
                    .truncationMode(.middle)
                    .opacity(dimmed)
                Spacer(minLength: 4)
                if session.isPinned(ref) { Image(systemName: "pin.fill").imageScale(.small) }
                if session.isSoloed(ref) { Image(systemName: "scope").imageScale(.small) }
                trailing()
                if session.isHidden(ref) { showButton(ref) }
            }
        }
        .foregroundStyle(selected ? Color.primary : Color.secondary)
        // The look of `SidebarItemStyle`: a neutral capsule when selected, a hover capsule otherwise.
        .padding(.leading, SidebarMetrics.capsuleLeading)
        .padding(.trailing, 10)
        .frame(minHeight: SidebarMetrics.rowHeight(textSize))
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Capsule().fill(selected ? Palette.selectedFill : hovered ? Palette.hoverFill : .clear))
        .overlay(Capsule().strokeBorder(selected ? Palette.selectedBorder : .clear, lineWidth: 1))
        .contentShape(Capsule())
        .padding(.leading, SidebarMetrics.rowLeading - SidebarMetrics.capsuleLeading + indent)
        .animation(Motion.hover, value: hovered)
        .onHover { hovered = $0 }
        .onTapGesture { session.selectRef(item) }
        .simultaneousGesture(TapGesture(count: 2).onEnded { RepoMenus.checkout(item, session) })
        .contextMenu { MenuEntriesView(entries: RepoMenus.ref(item, session)) }
        .help(name)
        .accessibilityElement(children: .combine)
        .accessibilityAddTraits(selected ? [.isButton, .isSelected] : .isButton)
        .accessibilityAction { session.selectRef(item) }
        .accessibilityAction(named: "Checkout") { RepoMenus.checkout(item, session) }
    }

    /// A hidden branch's or tag's eye: a click shows it again (not a branch hidden as stale while that is on).
    private func showButton(_ ref: String) -> some View {
        let stale = session.view.hideStale && session.isStale(ref) && !session.isPinned(ref)
        return Button { session.show(ref) } label: { Image(systemName: "eye.slash") }
            .buttonStyle(RowIconButtonStyle())
            .disabled(stale)
            .help(stale ? "Hidden as a stale branch: turn off Hide Stale Branches" : "Show Again")
            .accessibilityLabel("Show \(name)")
    }
}

/// `↑2 ↓1` against the upstream; "gone" when the upstream was deleted. Nothing when in sync or without upstream.
private struct AheadBehind: View {
    let branch: LocalBranch
    @Environment(\.textSize) private var textSize

    var body: some View {
        HStack(spacing: 4) {
            if branch.upstreamGone {
                Text("gone")
            } else {
                if branch.ahead > 0 { Text("\(Image(systemName: "arrow.up"))\(branch.ahead)") }
                if branch.behind > 0 { Text("\(Image(systemName: "arrow.down"))\(branch.behind)") }
            }
        }
        .font(textSize.caption)
        .monospacedDigit()
        .foregroundStyle(.secondary)
        .accessibilityElement(children: .combine)
        .accessibilityLabel(accessibilityText)
    }

    private var accessibilityText: String {
        if branch.upstreamGone { return "upstream gone" }
        return [branch.ahead > 0 ? "\(branch.ahead) ahead" : nil, branch.behind > 0 ? "\(branch.behind) behind" : nil]
            .compactMap { $0 }.joined(separator: ", ")
    }
}

/// A section card's rows while the refs load: icon circles and name capsules of the given widths (a fraction of the
/// row).
struct SkeletonRows: View {
    let fractions: [CGFloat]
    @Environment(\.textSize) private var textSize

    var body: some View {
        ForEach(fractions.indices, id: \.self) { index in
            HStack(spacing: SidebarMetrics.iconGap) {
                SkeletonLine(width: 14, height: 14)
                    .frame(width: SidebarMetrics.iconSlot, alignment: .leading)
                SkeletonLine(fraction: fractions[index], height: 11)
            }
            .padding(.leading, SidebarMetrics.rowLeading)
            .padding(.trailing, 10)
            .frame(height: SidebarMetrics.rowHeight(textSize))
        }
        .allowsHitTesting(false)
        .accessibilityHidden(true)
    }
}
