// The command palette's rows for one window, copied when it opens (task 8.5): Undo / Redo, the toolbar's repo actions and their
// Pull ▾ / Push ▾ menus, the repo menu and each submodule's menu, Show All Branches and Hide / Show Stale Branches,
// "Checkout <branch>" for every local and remote branch, the window's tabs, Open Repository…, the workspace commands
// and recent workspaces, the Settings pages, the tab position and the layout presets, the Settings switches and short
// choices (`PaletteSettings`), then
// the repo's menu operations (working tree, the selected commit, the stashes, each branch, remote branch and tag, the
// remotes). Every repo row runs the same `MenuEntry` or `ToolbarAction` the menus and buttons run, so its
// confirmations, forms and enabled state are theirs.
import AppKit
import HistqCore

/// The palette's groups, in the snapshot's order (the order of an empty query and of equal scores).
enum PaletteSection: String, Sendable {
    case repository = "Repository"
    case checkout = "Checkout"
    case tabs = "Tabs"
    case app = "Histq"
    case settings = "Settings"
    case operations = "Operations"
    /// The File History… and Blame… modal's rows (`FileSearchModal`), not the palette's.
    case files = "Files"
}

/// One palette row: what the list shows and searches. A value, so the ranking runs off the main actor; its action
/// stays on the main actor in the snapshot (`PaletteSnapshot.actions`). Disabled rows show dimmed and never run.
struct PaletteItem: Identifiable, Equatable, Sendable {
    /// Its index in the snapshot.
    let id: Int
    let title: String
    /// What it acts on or where it comes from ("Branch develop", "Pull ▾"), shown after the title and searched too.
    let detail: String
    let section: PaletteSection
    let systemImage: String
    let isEnabled: Bool

    /// The lowercased texts a keyword may hit, the title first (the ranking's tie-break compares it).
    var searchKeys: [String] { [title.lowercased(), detail.lowercased()] }
}

/// The rows of one palette opening and their actions, by row id.
struct PaletteSnapshot {
    private(set) var items: [PaletteItem] = []
    private(set) var actions: [Int: @MainActor () -> Void] = [:]

    mutating func add(_ title: String, detail: String, section: PaletteSection, systemImage: String,
                      enabled: Bool = true, perform: @escaping @MainActor () -> Void)
    {
        let id = items.count
        items.append(PaletteItem(id: id, title: title, detail: detail, section: section, systemImage: systemImage,
                                 isEnabled: enabled))
        actions[id] = perform
    }

    /// A menu's actions as rows: separators dropped, a submenu's items titled "Submenu › Item" (or left out when
    /// `submenus` rejects its title), a "Merge X into Y" submenu's as "Merge X into Y (fast-forward only)", entries whose
    /// title `skip` accepts left out (with their submenus).
    @MainActor mutating func add(_ entries: [MenuEntry], detail: String, section: PaletteSection = .operations,
                      systemImage: String, submenus: (String) -> Bool = { _ in true }, prefix: String = "",
                      skip: (String) -> Bool = { _ in false })
    {
        for entry in entries where !skip(entry.title) {
            switch entry.kind {
            case .separator:
                continue
            case .action(let perform):
                add(prefix + entry.title, detail: detail, section: section, systemImage: systemImage,
                    enabled: entry.isEnabled, perform: perform)
            case .submenu, .lazySubmenu:
                guard submenus(entry.title) else { continue }
                let children = entry.children
                guard RepoMenus.isMergeSubmenu(entry.title) else {
                    add(children, detail: detail, section: section, systemImage: systemImage,
                        prefix: prefix + entry.title + " › ", skip: skip)
                    continue
                }
                for child in children {
                    guard case .action(let perform) = child.kind else { continue }
                    let choice = RepoMenus.mergeChoices.first { $0.title == child.title }?.palette ?? child.title
                    add(prefix + entry.title + " (\(choice))", detail: detail, section: section,
                        systemImage: systemImage, enabled: child.isEnabled, perform: perform)
                }
            }
        }
    }
}

@MainActor
enum PaletteCommands {
    /// The window's rows now. Repo rows only while a repo tab shows (`actionSession`, as the toolbar's buttons).
    static func snapshot(for model: WindowModel) -> PaletteSnapshot {
        var snapshot = PaletteSnapshot()
        let session = model.actionSession
        if let session {
            repository(session, into: &snapshot)
            // A search of the tab's files; the pick opens its history or blame as File History and Blame do, or the
            // file editor.
            if let tabID = model.selectedTabID {
                for mode in [FileSearchMode.history, .blame, .edit] {
                    snapshot.add("\(mode.title)…", detail: "Search the repo's files", section: .repository,
                                 systemImage: mode.systemImage) { [weak model] in
                        UITiming.select("file search")
                        model?.presentModal(.fileSearch(tabID: tabID, mode: mode))
                    }
                }
            }
            checkouts(session, into: &snapshot)
        }
        tabs(model, into: &snapshot)
        app(model, into: &snapshot)
        settings(into: &snapshot)
        if let session { operations(session, into: &snapshot) }
        return snapshot
    }

    /// Undo and Redo (named and enabled as the toolbar's), the toolbar's buttons (enabled as they are), the Pull ▾
    /// and Push ▾ menus, the repo menu (with its Submodules submenu), each submodule's menu, then Show All Branches and
    /// Hide / Show Stale Branches.
    private static func repository(_ session: RepoSession, into snapshot: inout PaletteSnapshot) {
        for isRedo in [false, true] {
            let availability = session.historyAvailability(redo: isRedo)
            snapshot.add(isRedo ? "Redo" : "Undo", detail: availability.toolTip, section: .repository,
                         systemImage: isRedo ? "arrow.uturn.forward" : "arrow.uturn.backward",
                         enabled: availability.isEnabled) {
                if isRedo { session.redo() } else { session.undo() }
            }
        }
        for action in ToolbarAction.allCases {
            let isBusy = session.isRunning(action.key)
            snapshot.add(action.title, detail: action.help(session), section: .repository,
                         systemImage: action.systemImage, enabled: !isBusy && action.isEnabled(session)) {
                action.perform(session)
            }
        }
        snapshot.add(RepoMenus.pull(session), detail: "Pull ▾", section: .repository,
                     systemImage: ToolbarAction.pull.systemImage)
        snapshot.add(RepoMenus.push(session), detail: "Push ▾", section: .repository,
                     systemImage: ToolbarAction.push.systemImage)
        // Its Submodules submenu (Update All, Sync All) comes as "Submodules › …" rows.
        snapshot.add(RepoMenus.repository(session), detail: "Repository", section: .repository,
                     systemImage: "gauge.with.needle")
        for submodule in session.submodules.value ?? [] {
            snapshot.add(RepoMenus.submodule(submodule.path, session), detail: "Submodule \(submodule.path)",
                         section: .repository, systemImage: SidebarMetrics.submoduleImage)
        }
        snapshot.add("Show All Branches", detail: "Graph", section: .repository, systemImage: "eye",
                     enabled: session.hiddenCount > 0 || session.isSoloActive) { session.showAll() }
        let hideStale = session.view.hideStale
        snapshot.add(hideStale ? "Show Stale Branches" : "Hide Stale Branches", detail: "Graph › Older than 90 days",
                     section: .repository, systemImage: hideStale ? "eye" : "eye.slash") {
            session.setHideStale(!hideStale)
        }
    }

    /// Every local branch but the current one, then every remote branch, checked out as the sidebar's double-click
    /// does (`RepoMenus.checkout`). Disabled while a checkout runs, as the toolbar's branch menu is.
    private static func checkouts(_ session: RepoSession, into snapshot: inout PaletteSnapshot) {
        guard let refs = session.refs.value else { return }
        let enabled = !session.isRunning(.checkout)
        for branch in refs.localBranches where branch.name != session.currentBranch {
            snapshot.add("Checkout \(branch.name)", detail: "Local branch", section: .checkout,
                         systemImage: "lucide-git-branch", enabled: enabled) {
                RepoMenus.checkout(.local(branch.name), session)
            }
        }
        for branch in refs.remoteBranches {
            snapshot.add("Checkout \(branch.name)", detail: "Remote branch", section: .checkout, systemImage: "cloud",
                         enabled: enabled) {
                RepoMenus.checkout(.remote(branch.name), session)
            }
        }
    }

    /// The window's other tabs (selected as a click on them), New Tab, then Move Tab to Window: … for the current tab
    /// and each other window (`AppDelegate.moveTab`). Rows hold the model weakly: the model
    /// holds the palette, so a strong capture would keep a closed window's model and sessions alive.
    private static func tabs(_ model: WindowModel, into snapshot: inout PaletteSnapshot) {
        for tab in model.tabs where tab.id != model.selectedTabID || model.navigation.page != .home {
            let detail = tab.repoURL.map { ($0.path as NSString).abbreviatingWithTildeInPath } ?? "Welcome"
            snapshot.add("Switch to tab \(tab.title)", detail: detail, section: .tabs,
                         systemImage: tab.repoURL == nil ? "house" : "folder") { [weak model] in
                model?.selectTab(id: tab.id)
            }
        }
        snapshot.add("New Tab", detail: "⌘T", section: .tabs, systemImage: "plus") { [weak model] in
            model?.openTab(nil)
        }
        // The current tab alone, even in a multi-selection; a refused row shows why and never runs, a late refusal
        // shows as a toast (`TabDragOut.move`).
        guard let id = model.selectedTabID, let tab = model.tabs.first(where: { $0.id == id }),
              let app = NSApp.delegate as? AppDelegate else { return }
        for destination in app.moveDestinations(for: model) {
            let refusal = app.moveRefusal(id, from: model, to: destination)
            snapshot.add("Move Tab to Window: \(TabMenu.windowTitle(destination))",
                         detail: refusal ?? "Tab \(tab.title)", section: .tabs,
                         systemImage: "macwindow", enabled: refusal == nil) {
                [weak model, weak destination] in
                guard let model, let destination else { return }
                TabDragOut.move(id, from: model, to: destination)
            }
        }
    }

    /// Open Repository…, File's workspace commands (Close Workspace only in a workspace window) and the recent
    /// workspaces, the Settings pages, the tab position, the layout presets and Reset Layout.
    private static func app(_ model: WindowModel, into snapshot: inout PaletteSnapshot) {
        snapshot.add("Open Repository…", detail: "⌘O", section: .app, systemImage: "folder.badge.plus") {
            NSApp.sendAction(#selector(AppDelegate.openDocument(_:)), to: nil, from: nil)
        }
        var workspaceRows = [
            ("New Workspace", "plus.rectangle.on.rectangle", #selector(AppDelegate.newWorkspace(_:))),
            ("Open Workspace…", "square.stack.3d.up", #selector(AppDelegate.openWorkspaceDocument(_:))),
            ("Save Workspace As…", "square.and.arrow.down", #selector(AppDelegate.saveWorkspaceAs(_:))),
        ]
        if model.workspace != nil {
            workspaceRows.append(("Close Workspace", "xmark.square", #selector(AppDelegate.closeWorkspace(_:))))
        }
        for (title, image, action) in workspaceRows {
            snapshot.add(title, detail: "File › \(title)", section: .app, systemImage: image) {
                NSApp.sendAction(action, to: nil, from: nil)
            }
        }
        // File › Recent Workspaces: the item's `representedObject` is the file, as the menu's are.
        for url in RecentRepos.workspaces.urls {
            snapshot.add("Open Workspace: \(url.deletingPathExtension().lastPathComponent)",
                         detail: (url.path as NSString).abbreviatingWithTildeInPath, section: .app,
                         systemImage: "square.stack.3d.up") {
                let item = NSMenuItem()
                item.representedObject = url
                NSApp.sendAction(#selector(AppDelegate.openRecentWorkspace(_:)), to: nil, from: item)
            }
        }
        for section in SettingsSection.allCases {
            snapshot.add("Settings › \(section.label.title)", detail: "Settings", section: .app,
                         systemImage: section.label.icon) { [weak model] in
                model?.selectSettings(section)
            }
        }
        // General › Tab position: the same preference that page writes; the windows follow it live.
        let onLeft = TabPosition.current == .left
        snapshot.add(onLeft ? "Move Tabs to the Top" : "Move Tabs to the Left", detail: "General › Tab position",
                     section: .app, systemImage: onLeft ? "rectangle.topthird.inset.filled" : "sidebar.left") {
            Preferences.defaults.set(onLeft ? TabPosition.top.rawValue : TabPosition.left.rawValue,
                                     forKey: PrefKey.tabPosition.rawValue)
        }
        // The View menu's layout presets: Focus again leaves Focus.
        let preset = LayoutPreset.current
        for (row, image) in [(LayoutPreset.classic, "rectangle.split.3x1"), (.stacked, "rectangle.split.1x2"),
                             (.columns, "rectangle.rightthird.inset.filled"), (.focus, "rectangle")] {
            let title = row == .focus && preset == .focus ? "Leave Focus Layout" : "\(row.rawValue.capitalized) Layout"
            let detail = row == .focus ? "View › Layout ⌥⌘F" : "View › Layout"
            snapshot.add(title, detail: preset == row ? detail + " (current)" : detail, section: .app,
                         systemImage: image) {
                LayoutPreset.choose(row)
            }
        }
        snapshot.add("Reset Layout", detail: "View › Reset Layout", section: .app,
                     systemImage: "arrow.counterclockwise") { LayoutPreset.reset() }
    }

    /// The repo's context menus: the working tree's (when it has changes), the selected commit's or stash's, each
    /// stash's, the current branch's, every other branch's, each remote branch's and tag's, then the Remote card's.
    /// Their "Checkout …" items are left out (the Checkout rows run the same `RepoMenus.checkout`), and so are the
    /// commit menu's ref submenus (each ref has its own rows). Of another branch's submenus only its Merge choices are
    /// listed: its Set Upstream would add one row per remote branch for each local branch.
    private static func operations(_ session: RepoSession, into snapshot: inout PaletteSnapshot) {
        let refs = session.refs.value
        let current = session.currentBranch
        let isCheckout: (String) -> Bool = { $0.hasPrefix("Checkout ") }

        if session.status.value?.entries.isEmpty == false {
            snapshot.add(RepoMenus.wip(session), detail: "Working tree", systemImage: "pencil")
        }
        switch session.selection {
        case .commit(let hash):
            let refMenus = Set((refs?.localBranches.map { SidebarItem.local($0.name) } ?? [])
                .map(\.menuTitle) + (refs?.remoteBranches.map { SidebarItem.remote($0.name).menuTitle } ?? [])
                + (refs?.tags.map { SidebarItem.tag($0.name).menuTitle } ?? []))
            // "Checkout <branch>" duplicates a Checkout row; the detached checkout of this commit stays.
            snapshot.add(RepoMenus.commit(hash, session), detail: "Commit \(hash.prefix(7))",
                         systemImage: "smallcircle.filled.circle") { title in
                refMenus.contains(title) || (isCheckout(title) && !title.hasSuffix("(Detached)…"))
            }
        default:
            break
        }
        // The open diff's file: the header's File History and Blame (`DiffHeaderCard`).
        if let target = session.openFile, !target.isConflict, target.file.kind != .untracked, !target.file.isSubmodule {
            let rev: String? = switch target.source {
            case .wip: nil
            case .commit(let hash): hash
            case .compare(_, let head): head
            }
            snapshot.add(RepoMenus.fileTools(path: target.path, rev: rev,
                                             blame: target.file.kind != .deleted && !target.isImage, session: session),
                         detail: "File \((target.path as NSString).lastPathComponent)", systemImage: "doc.text")
        }
        for stash in session.log.value?.stashes ?? [] {
            snapshot.add(RepoMenus.stash(stash.hash, session), detail: "Stash \(stash.selector) \(stash.message)",
                         systemImage: "tray")
        }
        guard let refs else { return }
        if let current {
            snapshot.add(RepoMenus.ref(.local(current), session), detail: "Branch \(current)",
                         systemImage: "lucide-git-branch", skip: isCheckout)
        }
        for branch in refs.localBranches where branch.name != current {
            snapshot.add(RepoMenus.ref(.local(branch.name), session), detail: "Branch \(branch.name)",
                         systemImage: "lucide-git-branch", submenus: RepoMenus.isMergeSubmenu, skip: isCheckout)
        }
        for branch in refs.remoteBranches {
            snapshot.add(RepoMenus.ref(.remote(branch.name), session), detail: "Remote branch \(branch.name)",
                         systemImage: "cloud", skip: isCheckout)
        }
        for tag in refs.tags {
            snapshot.add(RepoMenus.ref(.tag(tag.name), session), detail: "Tag \(tag.name)", systemImage: "tag")
        }
        snapshot.add(RepoMenus.remotes(session), detail: "Remotes", systemImage: "network")
    }
}
