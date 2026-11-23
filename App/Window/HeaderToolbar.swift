// The window's toolbar, in the traffic-light row (house style, as EchoDiar and SegDown): at the leading edge the
// workspace's name (workspace windows only, with its read-only or not-saved warning), the repo menu (the window's repo
// tabs, recent repos, Open…), the branch menu (checks out the picked branch),
// and the tab's profile chip (`ProfilePicker`); at the trailing edge the green Update button while Sparkle has an update
// (`Updater`), then capsules of Undo / Redo, Pull ▾ / Push ▾ / Fetch, Branch / Stash / Pop, Row Height ▾ (the graph's
// row heights), then Terminal / Search / Settings. On a Welcome tab the repo actions are disabled, not removed.
// Settings is a modal over the tab (task 9.7), so the repo items stay as they are under it. While the onboarding runs
// no item takes a click, and a spotlight dims every item but its target (`Hold`); `frame(of:)` tells the spotlight
// where its toolbar targets are.
//
// The user can customize it (right-click › Customize Toolbar…): remove, re-add or move whole capsules, and add spaces.
// AppKit saves the layout in the standard defaults domain, under "NSToolbar Configuration HeaderToolbar"
// (`defaults read com.math2it.histq "NSToolbar Configuration HeaderToolbar"`), and keeps every window's toolbar in step
// (all share the identifier). A state-dir QA run (`-HistqStateDir`) neither reads nor saves it.
//
// An AppKit `NSToolbar`, not a SwiftUI `.toolbar`: a bridged SwiftUI toolbar takes part in every SwiftUI update pass of
// the window (about 10 ms per tab select with these items, see docs/later), even when its items depend on nothing.
// Here the items are built once; a narrow observation of the model only sets their titles, images and enabled state,
// and each menu is filled when it opens.
import AppKit
import HistqCore
import Observation

/// One window's toolbar: the `NSToolbar` delegate, the target of its items and the delegate of its menus. The window's
/// entry keeps it alive (`NSToolbar.delegate` is weak).
@MainActor
final class HeaderToolbar: NSObject, NSToolbarDelegate, NSMenuDelegate {
    let toolbar = NSToolbar(identifier: "HeaderToolbar")
    private let model: WindowModel
    private let updater: Updater

    // Fixed widths, so the items after them never move between tabs or branches (titles cut with "…"). Each keeps
    // the title's room it had before the icon's gap (`ToolbarDropdown.iconGap`) was added.
    private let repoItem = ToolbarDropdown(
        ID.repo, label: "Repository", width: 150 + ToolbarDropdown.iconGap,
        image: NSImage(systemSymbolName: "book.closed", accessibilityDescription: "Repository"))
    private let branchItem = ToolbarDropdown(
        ID.branch, label: "Branch", width: 160 + ToolbarDropdown.iconGap,
        image: NSImage.icon("lucide-git-branch", accessibilityDescription: "Branch"))
    /// As wide as its title (already cut at 24 characters), after its color dot.
    private let profileItem = ToolbarDropdown(ID.profile, label: "Profile", width: nil, image: nil)
    /// The color the profile chip's dot shows ("" for no profile, `missingProfileKey` for the warning), so the image is
    /// only redrawn when it changes.
    private var profileDot: String?
    #if DEBUG || HISTQ_PERF
    /// The branch button's last `<title> busy=<0|1>`, for its `op-feedback branch` timing line.
    private var branchFeedback: String?
    #endif
    /// The space between the profile chip's dot and its title.
    private static let profileDotGap: CGFloat = 5
    /// `profileDot` while the chip shows a missing profile's warning (never a color).
    private static let missingProfileKey = "missing"
    private let undoItem = NSToolbarItem(itemIdentifier: ID.undo)
    private let redoItem = NSToolbarItem(itemIdentifier: ID.redo)
    private let pullItem = NSMenuToolbarItem(itemIdentifier: ID.pull)
    private let pushItem = NSMenuToolbarItem(itemIdentifier: ID.push)
    private let fetchItem = NSToolbarItem(itemIdentifier: ID.fetch)
    private let createBranchItem = NSToolbarItem(itemIdentifier: ID.createBranch)
    private let stashItem = NSToolbarItem(itemIdentifier: ID.stash)
    private let popItem = NSToolbarItem(itemIdentifier: ID.pop)
    /// Pulls down the graph's row heights (`PrefKey.rowDensity`, as Settings › Appearance › Row height), its own
    /// capsule before Tools.
    private let rowHeightItem = NSMenuToolbarItem(itemIdentifier: ID.rowHeight)
    private let terminalItem = NSToolbarItem(itemIdentifier: ID.terminal)
    private let searchItem = NSToolbarItem(itemIdentifier: ID.search)
    private let settingsItem = NSToolbarItem(itemIdentifier: ID.settings)
    /// Its own capsule, green, first of the trailing ones, shown only while Sparkle has an update (as EchoDiar's).
    private let updateItem = NSToolbarItem(itemIdentifier: ID.update)
    /// The window's workspace: a pull-down with its name (the file's path as tooltip, or a warning when the file is
    /// read-only or its last write failed) and the workspace commands. Hidden in Untitled windows.
    private let workspaceItem = ToolbarDropdown(
        ID.workspace, label: "Workspace", width: nil,
        image: NSImage(systemSymbolName: workspaceSymbol, accessibilityDescription: "Workspace"))
    /// What `workspaceItem` shows now, so it is only written when it changes.
    private var workspaceShown: (text: String, toolTip: String, isWarning: Bool)?
    /// The saved configuration was checked for the workspace item this launch (`insertWorkspaceItemIfMissing`).
    private static var checkedWorkspaceItem = false
    private var groups: [NSToolbarItem.Identifier: NSToolbarItem] = [:]
    /// On macOS 26, the button showing each plain button item (`hoverButton`), by the item.
    private var hoverButtons: [ObjectIdentifier: ToolbarHoverButton] = [:]
    /// On macOS 26, the arrow of Pull ▾ and Push ▾ (`splitButton`), by the item: enabled with it.
    private var arrowButtons: [ObjectIdentifier: ToolbarHoverButton] = [:]
    /// How the onboarding holds the toolbar now, from the model in `apply`.
    private var hold = Hold.none

    /// How the onboarding holds the toolbar. AppKit draws the toolbar above the SwiftUI content, so neither its card's
    /// scrim nor the spotlight's dim covers it: the items hold themselves.
    private enum Hold: Equatable {
        case none
        /// The onboarding's cards: items with a view ignore clicks (`blocksInteraction`), looking as they are; items
        /// without one (before macOS 26) are disabled.
        case blocked
        /// A spotlight on `target`: its items (with a view) are drawn enabled but ignore clicks; every other item is
        /// disabled and, on macOS 26, its view dimmed to `dimmedAlpha`. Items without a view are only disabled.
        case spotlight(SpotlightTarget)

        static let dimmedAlpha: CGFloat = 0.25
    }

    /// The repo actions' buttons, by the operation each shows.
    private var actionItems: [(item: NSToolbarItem, action: ToolbarAction)] {
        [(pullItem, .pull), (pushItem, .push), (fetchItem, .fetch), (createBranchItem, .branch), (stashItem, .stash),
         (popItem, .pop)]
    }

    private enum ID {
        static let workspace = NSToolbarItem.Identifier("workspace")
        static let repo = NSToolbarItem.Identifier("repo")
        static let branch = NSToolbarItem.Identifier("branch")
        static let profile = NSToolbarItem.Identifier("profile")
        static let undo = NSToolbarItem.Identifier("undo")
        static let redo = NSToolbarItem.Identifier("redo")
        static let pull = NSToolbarItem.Identifier("pull")
        static let push = NSToolbarItem.Identifier("push")
        static let fetch = NSToolbarItem.Identifier("fetch")
        static let createBranch = NSToolbarItem.Identifier("createBranch")
        static let stash = NSToolbarItem.Identifier("stash")
        static let pop = NSToolbarItem.Identifier("pop")
        static let rowHeight = NSToolbarItem.Identifier("rowHeight")
        static let terminal = NSToolbarItem.Identifier("terminal")
        static let search = NSToolbarItem.Identifier("search")
        static let settings = NSToolbarItem.Identifier("settings")
        static let update = NSToolbarItem.Identifier("update")
        static let historyGroup = NSToolbarItem.Identifier("historyGroup")
        static let syncGroup = NSToolbarItem.Identifier("syncGroup")
        static let branchGroup = NSToolbarItem.Identifier("branchGroup")
        static let toolsGroup = NSToolbarItem.Identifier("toolsGroup")
    }

    init(model: WindowModel, updater: Updater) {
        self.model = model
        self.updater = updater
        super.init()
        configureItems()
        toolbar.delegate = self
        toolbar.displayMode = .iconOnly
        toolbar.allowsUserCustomization = true
        toolbar.allowsDisplayModeCustomization = false
        // The standard domain is the user's real one, whatever the run: a QA run keeps the default set.
        toolbar.autosavesConfiguration = !AppState.isStateDirMode
        model.spotlight.toolbarFrame = { [weak self] target in self?.frame(of: target) }
        observe()
    }

    // MARK: Items

    private func configureItems() {
        configureWorkspaceItem()
        for dropdown in [workspaceItem, repoItem, branchItem, profileItem] {
            dropdown.menu.delegate = self
            dropdown.overflowMenu.delegate = self
        }

        // Undo and Redo move through the tab's operation journal (enabled and named from it in `apply`); Terminal
        // shows or hides the tab's terminal drawer. Search opens the command palette.
        configureButton(undoItem, label: "Undo", systemImage: Self.undoSymbol)
        configureButton(redoItem, label: "Redo", systemImage: Self.redoSymbol)
        undoItem.action = #selector(undo(_:))
        redoItem.action = #selector(redo(_:))
        configureButton(terminalItem, label: "Terminal", systemImage: "terminal")
        terminalItem.action = #selector(toggleTerminal(_:))
        configureButton(searchItem, label: "Search", systemImage: "command")
        for item in [undoItem, redoItem, terminalItem] { item.isEnabled = false }
        searchItem.label = "Command Palette"
        searchItem.toolTip = "Command Palette (⌘K)"
        searchItem.action = #selector(togglePalette(_:))

        for (item, action) in actionItems {
            configureButton(item, label: action.title, systemImage: action.systemImage)
            item.action = selector(for: action)
        }
        // With an action, a menu item shows its menu from an arrow beside the button: Pull ▾ and Push ▾.
        for item in [pullItem, pushItem] {
            item.menu = makeMenu()
            item.showsIndicator = true
        }

        configureButton(settingsItem, label: "Settings", systemImage: "gearshape")
        settingsItem.action = #selector(toggleSettings(_:))

        // No action: a click pulls the menu down.
        configureButton(rowHeightItem, label: "Row Height", systemImage: Self.rowHeightSymbol)
        rowHeightItem.menu = makeMenu(Self.rowHeightMenuID)
        rowHeightItem.showsIndicator = true
        groups[ID.rowHeight] = rowHeightItem

        configureButton(updateItem, label: "Update", systemImage: Self.updateSymbol)
        updateItem.action = #selector(installUpdate(_:))
        updateItem.visibilityPriority = .high
        updateItem.isHidden = true
        groups[ID.update] = updateItem

        if PlatformFeatures.liquidGlass {
            // On macOS 26 the buttons draw their own hover (`ToolbarHoverButton`), Pull and Push with an arrow beside
            // them (`splitButton`). A capsule of several buttons is one item whose view is the row of them, never a
            // group of view items.
            let fetch = hoverButton(fetchItem)
            fetchItem.view = ToolbarHoverButton.capsule([fetch])
            fetchItem.menuFormRepresentation = fetch.menuForm
            // A bigger icon than the other buttons', so it stands out.
            let update = hoverButton(updateItem)
            update.iconColor = .systemGreen
            update.symbolConfiguration = NSImage.SymbolConfiguration(textStyle: .title2, scale: .large)
            update.image = updateItem.image
            updateItem.view = ToolbarHoverButton.capsule([update])
            updateItem.menuFormRepresentation = update.menuForm
            for item in [pullItem, pushItem] {
                item.view = splitButton(item)
                // In the overflow menu, the item's menu as a submenu, as AppKit's own menu item shows it.
                let form = NSMenuItem(title: item.label, action: nil, keyEquivalent: "")
                form.image = item.image
                form.submenu = makeMenu()
                item.menuFormRepresentation = form
            }
            // Its own menu, not the item's: AppKit hides the first item of an action-less menu item's menu (the
            // pull-down's title), here Compact.
            let rowHeight = hoverButton(rowHeightItem)
            rowHeight.dropdownMenu = makeMenu(Self.rowHeightMenuID)
            rowHeightItem.view = ToolbarHoverButton.capsule([rowHeight])
            let rowHeightForm = NSMenuItem(title: rowHeightItem.label, action: nil, keyEquivalent: "")
            rowHeightForm.image = rowHeightItem.image
            rowHeightForm.submenu = makeMenu(Self.rowHeightMenuID)
            rowHeightItem.menuFormRepresentation = rowHeightForm
            groups[ID.historyGroup] = row(ID.historyGroup, title: "History", [undoItem, redoItem])
            // Pull, Push and Fetch as items of their own, each in its own capsule (`toolbarDefaultItemIdentifiers`):
            // a group of view items shares one.
            for item in [pullItem, pushItem, fetchItem] { groups[item.itemIdentifier] = item }
            groups[ID.branchGroup] = row(ID.branchGroup, title: "Branch", [createBranchItem, stashItem, popItem])
            groups[ID.toolsGroup] = row(ID.toolsGroup, title: "Tools", [terminalItem, searchItem, settingsItem])
        } else {
            updateItem.image = updateItem.image?.withSymbolConfiguration(
                NSImage.SymbolConfiguration(paletteColors: [.systemGreen]))
            groups[ID.historyGroup] = group(ID.historyGroup, [undoItem, redoItem])
            groups[ID.syncGroup] = group(ID.syncGroup, [pullItem, pushItem, fetchItem])
            groups[ID.branchGroup] = group(ID.branchGroup, [createBranchItem, stashItem, popItem])
            groups[ID.toolsGroup] = group(ID.toolsGroup, [terminalItem, searchItem, settingsItem])
        }
        for (id, item) in groups { if let palette = Self.palette[id] { item.paletteLabel = palette.label } }
    }

    /// The workspace pull-down: as wide as its name (cut in `apply`), its menu built on open (`workspaceEntries`).
    private func configureWorkspaceItem() {
        // A plain name is the first to go to the overflow menu when the toolbar is full (the default width has about
        // 100 pt free); a warning stays (`applyWorkspace` raises it), so an unsaved workspace is never hidden.
        workspaceItem.item.visibilityPriority = .low
        workspaceItem.item.isHidden = true
    }

    /// A menu whose items are built when it opens (`menuNeedsUpdate`), never on a model change.
    private func makeMenu(_ identifier: NSUserInterfaceItemIdentifier? = nil) -> NSMenu {
        let menu = NSMenu()
        menu.identifier = identifier
        menu.autoenablesItems = false
        menu.delegate = self
        return menu
    }

    private func configureButton(_ item: NSToolbarItem, label: String, systemImage: String) {
        item.label = label
        item.paletteLabel = label
        item.toolTip = label
        item.image = NSImage.icon(systemImage, accessibilityDescription: label, size: 20)
        item.isBordered = true
        item.target = self
        // Its state is set from the model, never validated by AppKit.
        item.autovalidates = false
    }

    /// The button standing for a configured button item (its image, action, label, tooltip and state), which `set`
    /// keeps in step with the item from then on.
    private func hoverButton(_ item: NSToolbarItem) -> ToolbarHoverButton {
        let button = ToolbarHoverButton(target: self, action: item.action, label: item.label)
        button.image = item.image
        button.toolTip = item.toolTip
        button.isEnabled = item.isEnabled
        hoverButtons[ObjectIdentifier(item)] = button
        return button
    }

    /// Pull ▾ or Push ▾ on macOS 26: the action's button and an arrow pulling down the item's menu, in one capsule
    /// without the line AppKit's own menu item draws between them.
    private func splitButton(_ item: NSMenuToolbarItem) -> NSView {
        let label = "\(item.label) Options"
        // As big as the action's button and its icon, as EchoDiar's record ▾.
        let arrow = ToolbarHoverButton(target: self, action: nil, label: label)
        arrow.image = NSImage(systemSymbolName: "chevron.down", accessibilityDescription: label)
        arrow.toolTip = label
        arrow.isEnabled = item.isEnabled
        arrow.dropdownMenu = item.menu
        arrowButtons[ObjectIdentifier(item)] = arrow
        return ToolbarHoverButton.capsule([hoverButton(item), arrow])
    }

    /// One bordered item, so one capsule, showing `subitems` as a row of `ToolbarHoverButton`s; in the overflow menu,
    /// `title` with a submenu of them.
    private func row(_ id: NSToolbarItem.Identifier, title: String, _ subitems: [NSToolbarItem],
                     spacing: CGFloat = 0) -> NSToolbarItem
    {
        let buttons = subitems.map { hoverButton($0) }
        let stack = ToolbarHoverButton.capsule(buttons, spacing: spacing)
        let item = NSToolbarItem(itemIdentifier: id)
        item.view = stack
        item.isBordered = true
        item.label = ""
        item.paletteLabel = title
        item.autovalidates = false
        let form = NSMenuItem(title: title, action: nil, keyEquivalent: "")
        form.submenu = NSMenu()
        form.submenu?.autoenablesItems = false
        form.submenu?.items = buttons.map(\.menuForm)
        item.menuFormRepresentation = form
        return item
    }

    private func group(_ id: NSToolbarItem.Identifier, _ subitems: [NSToolbarItem]) -> NSToolbarItemGroup {
        let group = NSToolbarItemGroup(itemIdentifier: id)
        group.subitems = subitems
        group.autovalidates = false
        group.label = ""
        return group
    }

    // MARK: NSToolbarDelegate

    func toolbarDefaultItemIdentifiers(_ toolbar: NSToolbar) -> [NSToolbarItem.Identifier] {
        // On macOS 26 a fixed space starts a new capsule; before, there are no capsules to separate.
        let gap: [NSToolbarItem.Identifier] = PlatformFeatures.liquidGlass ? [.space] : []
        let sync = PlatformFeatures.liquidGlass ? [ID.pull] + gap + [ID.push] + gap + [ID.fetch] : [ID.syncGroup]
        // The Update button right after the flexible space: hidden, it and its gap only widen the empty middle.
        return [ID.workspace, ID.repo, ID.branch, ID.profile, .flexibleSpace, ID.update] + gap + [ID.historyGroup] + gap
            + sync + gap + [ID.branchGroup] + gap + [ID.rowHeight] + gap + [ID.toolsGroup]
    }

    /// Each default item once, then the spaces (the default set repeats `.space`).
    func toolbarAllowedItemIdentifiers(_ toolbar: NSToolbar) -> [NSToolbarItem.Identifier] {
        let items = toolbarDefaultItemIdentifiers(toolbar).filter { $0 != .space && $0 != .flexibleSpace }
        return items.reduce(into: []) { if !$0.contains($1) { $0.append($1) } } + [.space, .flexibleSpace]
    }

    func toolbar(_ toolbar: NSToolbar, itemForItemIdentifier itemIdentifier: NSToolbarItem.Identifier,
                 willBeInsertedIntoToolbar flag: Bool) -> NSToolbarItem?
    {
        // The customization palette's sample: a new item, as the live one's view would leave the window's toolbar.
        guard flag else { return Self.paletteItem(itemIdentifier) }
        return switch itemIdentifier {
        case ID.workspace: workspaceItem.item
        case ID.repo: repoItem.item
        case ID.branch: branchItem.item
        case ID.profile: profileItem.item
        default: groups[itemIdentifier]
        }
    }

    /// Each item's name and icon in the customization palette.
    private static let palette: [NSToolbarItem.Identifier: (label: String, image: String)] = [
        ID.workspace: ("Workspace", workspaceSymbol),
        ID.repo: ("Repository", "book.closed"),
        ID.branch: ("Branch", "lucide-git-branch"),
        ID.profile: ("Profile", "person.crop.circle"),
        ID.historyGroup: ("Undo / Redo", undoSymbol),
        ID.syncGroup: ("Sync", ToolbarAction.fetch.systemImage),
        ID.pull: ("Pull", ToolbarAction.pull.systemImage),
        ID.push: ("Push", ToolbarAction.push.systemImage),
        ID.fetch: ("Fetch", ToolbarAction.fetch.systemImage),
        ID.branchGroup: ("Branch Actions", ToolbarAction.stash.systemImage),
        ID.rowHeight: ("Row Height", rowHeightSymbol),
        ID.toolsGroup: ("Tools", "terminal"),
        ID.update: ("Update", updateSymbol),
    ]

    private static func paletteItem(_ id: NSToolbarItem.Identifier) -> NSToolbarItem? {
        guard let palette = palette[id] else { return nil }
        let item = NSToolbarItem(itemIdentifier: id)
        item.label = palette.label
        item.paletteLabel = palette.label
        item.image = NSImage.icon(palette.image, accessibilityDescription: palette.label, size: 20)
        return item
    }

    /// Adds the workspace item at the leading edge when the saved configuration (from a build without it) lacks it,
    /// once per launch, not on every workspace join; every window shares the configuration, so all of them get it
    /// (hidden in Untitled windows). Called once the toolbar is in its window, so its items are loaded.
    func insertWorkspaceItemIfMissing() {
        guard !Self.checkedWorkspaceItem else { return }
        Self.checkedWorkspaceItem = true
        guard !toolbar.items.contains(where: { $0.itemIdentifier == ID.workspace }) else { return }
        toolbar.insertItem(withItemIdentifier: ID.workspace, at: 0)
    }

    /// Whether this toolbar shows and has the Update slot (the user may have removed it in Customize Toolbar).
    var hasUpdateItem: Bool {
        toolbar.isVisible && toolbar.items.contains { $0.itemIdentifier == ID.update }
    }

    // MARK: State

    /// Applies the model to the items, then applies it again after the next change of what it read. Only the
    /// window's workspace (name, path, read-only and write state), the selected tab's repo, its session's refs,
    /// running operations, status, stashes, remotes, profile, undo status, operation in progress and terminal drawer,
    /// the profile store, the page, the Settings modal, whether the onboarding runs, the spotlight's target and whether
    /// Sparkle has an update are read, so other tabs and the content's own state never wake the toolbar.
    private func observe() {
        withObservationTracking {
            apply()
        } onChange: { [weak self] in
            // Called before the change lands, off any isolation: apply on the main actor once it has.
            Task { @MainActor [weak self] in self?.observe() }
        }
    }

    private func apply() {
        let spotlight = model.spotlight.activeTarget
        hold = spotlight.map(Hold.spotlight) ?? (model.isOnboarding ? .blocked : .none)
        applyWorkspace()
        // No Customize Toolbar (its menu items, View's) while the onboarding or a spotlight runs over the window.
        let customizable = hold == .none
        if toolbar.allowsUserCustomization != customizable { toolbar.allowsUserCustomization = customizable }
        let selected = model.selectedIndex.map { model.tabs[$0] }
        let session = model.actionSession
        // The folder's name, never the tab's alias: the alias only shortens the tab itself.
        repoItem.title = selected?.repoURL?.lastPathComponent ?? "Histq"
        repoItem.toolTip = selected?.repoURL?.path ?? "Switch repository"

        if branchItem.item.isHidden != (session == nil) {
            branchItem.item.isHidden = session == nil
            // Without a new measure after the toolbar has laid out the branch item's new state, the repo item
            // keeps a 4 pt narrower slot until its size is next invalidated (its menu first filled), then moves by
            // 2 pt and the items after it by 4.
            DispatchQueue.main.async { [repoItem] in
                repoItem.button.window?.layoutIfNeeded()
                repoItem.button.invalidateIntrinsicContentSize()
            }
        }
        if let session {
            let isBusy = session.isRunning(.checkout)
            // While a checkout runs, its target at once; the refs' head again once it ends (failed too).
            let target = Self.checkoutTarget(session)
            let title = target ?? Self.branchTitle(session.refs.value?.head)
            branchItem.title = title
            branchItem.isEnabled = gated(branchItem.item, !isBusy && session.refs.value != nil)
            // The full name, as the title may be cut.
            branchItem.toolTip = isBusy ? target.map { "Checking out \($0)…" } ?? "Checking out…"
                : "\(title): check out another branch"
            #if DEBUG || HISTQ_PERF
            let feedback = "\(title) busy=\(isBusy ? 1 : 0)"
            if branchFeedback != feedback {
                branchFeedback = feedback
                UITiming.opFeedback("branch \(feedback)")
            }
            #endif
        }

        // Hidden, like the branch menu, where no repo tab shows (Welcome).
        set(profileItem.item, hidden: session == nil)
        if let session, let missing = session.missingProfile {
            // A workspace profile this Mac lacks: the warning triangle instead of the dot and only the name (as wide as
            // a normal chip, so the toolbar does not overflow); "Profile missing" is in the tooltip and the menu.
            profileItem.title = Self.truncated(missing.name, 24)
            profileItem.toolTip = "Profile missing. " + ProfilePicker.missingToolTip(missing)
            if profileDot != Self.missingProfileKey {
                profileDot = Self.missingProfileKey
                profileItem.image = ProfilePicker.warning(gap: Self.profileDotGap)
            }
        } else if let session {
            let profile = session.profile
            profileItem.title = Self.truncated(ProfilePicker.title(profile), 24)
            profileItem.toolTip = ProfilePicker.toolTip(profile)
            let dot = profile?.color ?? ""
            if profileDot != dot {
                profileDot = dot
                profileItem.image = ProfilePicker.dot(hex: profile?.color, gap: Self.profileDotGap)
            }
        }

        for (item, action) in actionItems {
            let isBusy = session?.isRunning(action.key) ?? false
            set(item, enabled: session.map { !isBusy && action.isEnabled($0) } ?? false)
            set(item, systemImage: isBusy ? Self.busySymbol : action.systemImage, label: action.title)
            set(item, toolTip: isBusy ? "\(action.title): running…" : session.map(action.help) ?? action.title)
        }

        for (item, isRedo) in [(undoItem, false), (redoItem, true)] {
            let label = isRedo ? "Redo" : "Undo"
            let availability = session?.historyAvailability(redo: isRedo) ?? (isEnabled: false, toolTip: label)
            let isBusy = session?.isRunning(isRedo ? .redo : .undo) ?? false
            set(item, enabled: availability.isEnabled)
            set(item, toolTip: availability.toolTip)
            set(item, systemImage: isBusy ? Self.busySymbol : isRedo ? Self.redoSymbol : Self.undoSymbol, label: label)
        }
        #if DEBUG
        logUndoItem()
        #endif

        let isTerminalOpen = session?.isTerminalOpen ?? false
        set(terminalItem, enabled: session != nil)
        // A pending drawer: the button starts its shell, so it does not offer to hide it.
        let hidesTerminal = isTerminalOpen && session?.isTerminalPending == false
        set(terminalItem, toolTip: hidesTerminal ? "Hide Terminal (⌃`)" : "Show Terminal (⌃`)")
        set(terminalItem, systemImage: isTerminalOpen ? "terminal.fill" : "terminal", label: "Terminal")

        let isSettings = model.isSettingsOpen
        set(settingsItem, systemImage: isSettings ? "gearshape.fill" : "gearshape", label: "Settings")

        set(updateItem, hidden: !updater.updateAvailable)
        if let version = updater.availableUpdateVersion { set(updateItem, toolTip: "Install Histq \(version)") }
        applyHold()
        if spotlight != nil {
            // Once the toolbar has laid out what this pass changed, the spotlight reads its target's frame again.
            DispatchQueue.main.async { [model] in model.spotlight.frameMayHaveChanged() }
        }
        #if DEBUG
        logItemFrames()
        #endif
    }

    // MARK: Hold

    /// The button items, each with its view on macOS 26 (`view(of:)`).
    private var buttonItems: [NSToolbarItem] {
        [undoItem, redoItem, pullItem, pushItem, fetchItem, createBranchItem, stashItem, popItem, rowHeightItem,
         terminalItem, searchItem, settingsItem, updateItem]
    }

    private var dropdowns: [ToolbarDropdown] { [workspaceItem, repoItem, branchItem, profileItem] }

    /// The view showing `item` in the toolbar: its own (a dropdown, Pull ▾ / Push ▾, Fetch, Row Height, Update) or its
    /// button in a row's capsule; nil before macOS 26 for the button items (subitems of a group).
    private func view(of item: NSToolbarItem) -> NSView? {
        item.view ?? hoverButtons[ObjectIdentifier(item)]
    }

    /// The items a spotlight on `target` keeps bright; none for a content target.
    private func items(for target: SpotlightTarget) -> [NSToolbarItem] {
        switch target {
        case .workspaceMenu: [workspaceItem.item]
        case .repoMenu: [repoItem.item]
        case .branchMenu: [branchItem.item]
        case .profile: [profileItem.item]
        case .history: [undoItem, redoItem]
        case .sync: [pullItem, pushItem, fetchItem]
        case .branchActions: [createBranchItem, stashItem, popItem]
        case .terminal: [terminalItem]
        case .search: [searchItem]
        default: []
        }
    }

    /// `enabled` as the hold leaves it (`Hold`).
    private func gated(_ item: NSToolbarItem, _ enabled: Bool) -> Bool {
        switch hold {
        case .none: enabled
        case .blocked: enabled && view(of: item) != nil
        case .spotlight(let target): view(of: item) != nil && items(for: target).contains { $0 === item }
        }
    }

    /// The hold on the items `apply` sets no state for, then on every item's view: clicks blocked while the onboarding
    /// runs, the views other than the spotlight's target dimmed.
    private func applyHold() {
        for item in [searchItem, settingsItem, rowHeightItem, updateItem] { set(item, enabled: true) }
        for dropdown in [workspaceItem, repoItem, profileItem] { dropdown.isEnabled = gated(dropdown.item, true) }
        let blocks = hold != .none
        for button in Array(hoverButtons.values) + Array(arrowButtons.values) { button.blocksInteraction = blocks }
        for dropdown in dropdowns { dropdown.blocksInteraction = blocks }
        // Before macOS 26 only the dropdowns have views: no item is dimmed there (the band stays lit instead).
        guard PlatformFeatures.liquidGlass else { return }
        let bright: [NSToolbarItem]? = if case .spotlight(let target) = hold { items(for: target) } else { nil }
        for item in buttonItems + dropdowns.map(\.item) {
            guard let view = view(of: item) else { continue }
            let alpha = bright.map { $0.contains { $0 === item } ? 1 : Hold.dimmedAlpha } ?? 1
            if view.alphaValue != alpha { view.alphaValue = alpha }
        }
    }

    /// Where `target`'s items show, in window top-left coordinates (the union of their views; a row's whole capsule
    /// for Undo / Redo and Branch / Stash / Pop), for the spotlight; nil when none shows in the window: no view (before
    /// macOS 26), removed in Customize Toolbar, in the overflow menu, hidden, or the toolbar in a full-screen window's
    /// own window. The same conversion as the DEBUG `-HistqToolbarFrames` probe, then flipped to top-left.
    func frame(of target: SpotlightTarget) -> CGRect? {
        guard let window = model.window, let content = window.contentView else { return nil }
        let shown: [(item: NSToolbarItem, view: NSView?)] = switch target {
        case .history: [(undoItem, groups[ID.historyGroup]?.view)]
        case .branchActions: [(createBranchItem, groups[ID.branchGroup]?.view)]
        default: items(for: target).map { ($0, view(of: $0)) }
        }
        let rects = shown.compactMap { item, view -> CGRect? in
            guard !item.isHidden, let view, view.window === window, !view.isHiddenOrHasHiddenAncestor
            else { return nil }
            var rect = content.convert(view.convert(view.bounds, to: nil), from: nil)
            if !content.isFlipped { rect.origin.y = content.bounds.height - rect.maxY }
            return rect
        }
        guard let first = rects.first else { return nil }
        return rects.dropFirst().reduce(first) { $0.union($1) }
    }

    /// The workspace label from the window's workspace (its name, path, read-only flag and last write's error), hidden
    /// in an Untitled window. The toolbar has about 100 pt free at the default width, so only a short name shows; a
    /// read-only file or a failed write turns it into a warning (triangle, a toast's orange) and the tooltip says why.
    private func applyWorkspace() {
        guard let workspace = model.workspace else {
            set(workspaceItem.item, hidden: true)
            return
        }
        let name = Self.truncated(workspace.name, 12)
        let path = (workspace.url.path as NSString).abbreviatingWithTildeInPath
        let reason = workspace.writeError ?? "the file could not be written"
        let shown: (text: String, toolTip: String, isWarning: Bool) = if workspace.isReadOnly {
            (name,
             "\(path)\nRead-only: made by a newer Histq, so changes to this workspace are not saved. "
                 + "Save Workspace As… makes a copy this version saves.", true)
        } else if workspace.writeFailed {
            (name,
             "\(path)\nNot saved: \(reason)\nChanges to this workspace are not saved until a write succeeds.", true)
        } else {
            (name, path, false)
        }
        if workspaceShown?.text != shown.text || workspaceShown?.toolTip != shown.toolTip
            || workspaceShown?.isWarning != shown.isWarning
        {
            if workspaceShown?.isWarning != shown.isWarning {
                // The orange triangle (as the missing-profile chip), else the stack icon as a template.
                workspaceItem.image = shown.isWarning
                    ? ProfilePicker.warning(gap: ToolbarDropdown.iconGap)
                    : NSImage(systemSymbolName: Self.workspaceSymbol, accessibilityDescription: "Workspace")
                        .map(ToolbarDropdown.padded)
            }
            workspaceShown = shown
            workspaceItem.item.visibilityPriority = shown.isWarning ? .high : .low
            workspaceItem.title = shown.text
            workspaceItem.toolTip = shown.toolTip
            let state = workspace.isReadOnly ? ", read-only" : workspace.writeFailed ? ", not saved" : ""
            workspaceItem.button.setAccessibilityLabel("Workspace \(shown.text)\(state)")
        }
        set(workspaceItem.item, hidden: false)
    }

    // Each setter writes only a changed value: an unchanged write still relayouts the toolbar.

    private func set(_ item: NSToolbarItem, title: String) {
        if item.title != title { item.title = title }
    }

    /// Writes `enabled` as the hold leaves it (`gated`).
    private func set(_ item: NSToolbarItem, enabled: Bool) {
        let enabled = gated(item, enabled)
        guard item.isEnabled != enabled else { return }
        item.isEnabled = enabled
        hoverButtons[ObjectIdentifier(item)]?.isEnabled = enabled
        arrowButtons[ObjectIdentifier(item)]?.isEnabled = enabled
    }

    private func set(_ item: NSToolbarItem, toolTip: String) {
        guard item.toolTip != toolTip else { return }
        item.toolTip = toolTip
        hoverButtons[ObjectIdentifier(item)]?.toolTip = toolTip
    }

    private func set(_ item: NSToolbarItem, hidden: Bool) {
        if item.isHidden != hidden { item.isHidden = hidden }
    }

    private var symbols: [ObjectIdentifier: String] = [:]

    private func set(_ item: NSToolbarItem, systemImage: String, label: String) {
        guard symbols[ObjectIdentifier(item)] != systemImage else { return }
        symbols[ObjectIdentifier(item)] = systemImage
        // A symbol this system lacks keeps the current icon rather than an empty button.
        guard let image = NSImage.icon(systemImage, accessibilityDescription: label, size: 20) else { return }
        item.image = image
        hoverButtons[ObjectIdentifier(item)]?.image = image
        if systemImage == Self.busySymbol { UITiming.opFeedback("toolbar \(label)") }
    }

    /// In place of a running action's icon (there is no spinner in a toolbar button without a custom view).
    private static let busySymbol = "progress.indicator"
    private static let undoSymbol = "arrow.uturn.backward"
    private static let redoSymbol = "arrow.uturn.forward"
    private static let updateSymbol = "arrow.down.circle.fill"
    private static let workspaceSymbol = "square.stack.3d.up"
    private static let rowHeightSymbol = "arrow.up.and.down.text.horizontal"
    /// Marks the Row Height menus (the item's, the macOS 26 button's and the overflow's) for `menuNeedsUpdate`.
    private static let rowHeightMenuID = NSUserInterfaceItemIdentifier("rowHeight")

    #if DEBUG
    private var loggedUndoItem: String?

    /// DEBUG `-HistqLogUndo`: appends the Undo button's enabled state and tooltip to `operations.txt` each time they
    /// change (a screenshot cannot show a tooltip).
    private func logUndoItem() {
        guard ProcessInfo.processInfo.arguments.contains("-HistqLogUndo") else { return }
        let line = "toolbar undo enabled=\(undoItem.isEnabled) toolTip=\(undoItem.toolTip ?? "")"
        guard line != loggedUndoItem else { return }
        loggedUndoItem = line
        RepoMenus.debugLog(line)
    }

    /// DEBUG `-HistqToolbarFrames YES`: after each `apply`, once the toolbar has laid out, logs the repo and branch
    /// dropdowns' frames in window coordinates (`toolbar repo=<x>,<w> branch=<x>,<w>`) to `timing.log`.
    private func logItemFrames() {
        guard AppState.launchToolbarFrames else { return }
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) { [weak self] in
            guard let self else { return }
            // A dropdown the user removed from the toolbar has no window, so no frame.
            let shown = [("repo", repoItem), ("branch", branchItem)].filter { $0.1.button.window != nil }
            guard !shown.isEmpty else { return }
            let frames = shown.map { name, dropdown in
                let frame = dropdown.button.convert(dropdown.button.bounds, to: nil)
                return "\(name)=\(Int(frame.minX.rounded())),\(Int(frame.width.rounded()))"
            }
            UITiming.toolbar(frames.joined(separator: " "))
        }
    }

    #endif

    private static func branchTitle(_ head: Head?) -> String {
        switch head {
        case .branch(let name, _), .unborn(let name): name
        case .detached(let commit): "\(commit.prefix(7)) detached"
        case nil: "…"
        }
    }

    /// The name a running checkout's title gives after "Checkout ": every `.checkout` operation is titled
    /// "Checkout \(name)" in `GraphMenus.swift` (`checkoutAskingIfDirty`; `confirmDetached` names the tag or the
    /// short hash). Nil when no checkout runs or its title has another form.
    private static func checkoutTarget(_ session: RepoSession) -> String? {
        let prefix = "Checkout "
        guard let title = session.running.last(where: { $0.key == .checkout })?.title, title.hasPrefix(prefix)
        else { return nil }
        return String(title.dropFirst(prefix.count))
    }

    /// `text` cut with "…" after `limit` characters (a toolbar button without a view has no width limit; the repo and
    /// branch dropdowns have one and cut their titles themselves).
    private static func truncated(_ text: String, _ limit: Int) -> String {
        text.count > limit ? String(text.prefix(limit - 1)) + "…" : text
    }

    // MARK: Actions

    // One method per action: from the overflow menu or a collapsed group the sender is not the toolbar item.
    @objc private func pull(_ sender: Any?) { perform(.pull) }
    @objc private func push(_ sender: Any?) { perform(.push) }
    @objc private func fetch(_ sender: Any?) { perform(.fetch) }
    @objc private func createBranch(_ sender: Any?) { perform(.branch) }
    @objc private func stash(_ sender: Any?) { perform(.stash) }
    @objc private func pop(_ sender: Any?) { perform(.pop) }
    @objc private func undo(_ sender: Any?) { if hold == .none { model.actionSession?.undo() } }
    @objc private func redo(_ sender: Any?) { if hold == .none { model.actionSession?.redo() } }

    private func selector(for action: ToolbarAction) -> Selector {
        switch action {
        case .pull: #selector(pull(_:))
        case .push: #selector(push(_:))
        case .fetch: #selector(fetch(_:))
        case .branch: #selector(createBranch(_:))
        case .stash: #selector(stash(_:))
        case .pop: #selector(pop(_:))
        }
    }

    private func perform(_ action: ToolbarAction) {
        // From the overflow menu too: nothing while the onboarding holds the toolbar.
        guard hold == .none, let session = model.actionSession else { return }
        action.perform(session)
    }

    @objc private func toggleSettings(_ sender: Any?) {
        if hold == .none { model.toggleSettings() }
    }

    @objc private func toggleTerminal(_ sender: Any?) {
        if hold == .none { model.toggleTerminal() }
    }

    @objc private func togglePalette(_ sender: Any?) {
        if hold == .none { model.togglePalette() }
    }

    @objc private func installUpdate(_ sender: Any?) {
        if hold == .none { updater.checkForUpdates() }
    }

    // MARK: Menus

    func menuNeedsUpdate(_ menu: NSMenu) {
        // Empty while the onboarding holds the toolbar (a menu opened from the overflow menu).
        let entries: [MenuEntry] = if hold != .none { [] } else { switch menu {
        case workspaceItem.menu, workspaceItem.overflowMenu: workspaceEntries()
        case repoItem.menu, repoItem.overflowMenu: repoEntries()
        case branchItem.menu, branchItem.overflowMenu: model.actionSession.map(RepoMenus.branchPicker) ?? []
        case profileItem.menu, profileItem.overflowMenu:
            if let session = model.actionSession, let id = model.selectedTabID {
                ProfilePicker.entries(tab: id, current: session.profile?.id, model: model)
            } else { [] }
        case pullItem.menu, pullItem.menuFormRepresentation?.submenu: model.actionSession.map(RepoMenus.pull) ?? []
        case pushItem.menu, pushItem.menuFormRepresentation?.submenu: model.actionSession.map(RepoMenus.push) ?? []
        case _ where menu.identifier == Self.rowHeightMenuID: Self.rowHeightEntries()
        default: []
        } }
        let built = MenuBuilder.menu(entries)
        var items = built.items
        built.removeAllItems()
        if menu === repoItem.menu || menu === repoItem.overflowMenu,
           let index = items.firstIndex(where: { $0.title == Self.recentMarker })
        {
            // The recent repos under a section header.
            items[index] = NSMenuItem.sectionHeader(title: "Recent")
        }
        if menu === workspaceItem.menu || menu === workspaceItem.overflowMenu,
           let index = items.firstIndex(where: { $0.title == Self.recentMarker })
        {
            items[index] = NSMenuItem.sectionHeader(title: "Recent Workspaces")
        }
        if let dropdown = [workspaceItem, repoItem, branchItem, profileItem].first(where: { $0.menu === menu }) {
            menu.items = [dropdown.titleItem] + items
        } else if menu.identifier == Self.rowHeightMenuID {
            menu.items = [NSMenuItem.sectionHeader(title: "Row Height")] + items
        } else {
            menu.items = items
        }
    }

    /// The row heights, the current one checked. A pick writes the defaults Settings' picker writes (its
    /// `@AppStorage`), so every graph and Settings take it at once.
    private static func rowHeightEntries() -> [MenuEntry] {
        let key = PrefKey.rowDensity.rawValue
        let current = Preferences.defaults.string(forKey: key) ?? "regular"
        return ["compact", "regular", "comfortable"].map { density in
            .action(density.capitalized, checked: density == current) { Preferences.defaults.set(density, forKey: key) }
        }
    }

    /// Stands for the "Recent" section header in `repoEntries`, which `MenuEntry` cannot express.
    private static let recentMarker = "\u{1}recent"

    /// The window's workspace commands: Reveal in Finder, Save Workspace As…, Close Workspace, the recent workspaces
    /// other than this one (a pick opens it, or brings it forward), then New Workspace and Open Workspace….
    private func workspaceEntries() -> [MenuEntry] {
        guard let workspace = model.workspace else { return [] }
        func send(_ action: Selector) { NSApp.sendAction(action, to: nil, from: nil) }
        var entries: [MenuEntry] = [
            .action("Reveal in Finder") { NSWorkspace.shared.activateFileViewerSelecting([workspace.url]) },
            .action("Save Workspace As…") { send(#selector(AppDelegate.saveWorkspaceAs(_:))) },
            .action("Close Workspace") { send(#selector(AppDelegate.closeWorkspace(_:))) },
        ]
        let key = workspace.url.standardizedFileURL.path
        let recent = RecentRepos.workspaces.urls.filter { $0.standardizedFileURL.path != key }
        if !recent.isEmpty {
            entries += [.separator, .action(Self.recentMarker, enabled: false) {}]
            entries += recent.map { url in
                .action(url.deletingPathExtension().lastPathComponent) {
                    (NSApp.delegate as? AppDelegate)?.openWorkspace(url)
                }
            }
        }
        entries += [
            .separator,
            .action("New Workspace") { send(#selector(AppDelegate.newWorkspace(_:))) },
            .action("Open Workspace…") { send(#selector(AppDelegate.openWorkspaceDocument(_:))) },
        ]
        return entries
    }

    /// The window's repo tabs (the selected one checked; a pick selects that tab at once, as a click on it does), the
    /// recent repos not open here (a pick opens it as `openTab`), then Open…, then the tab's repository actions
    /// (`RepoMenus.repository`).
    private func repoEntries() -> [MenuEntry] {
        let repoTabs = model.tabs.filter { $0.repoURL != nil }
        let openPaths = Set(repoTabs.compactMap { $0.repoURL?.path })
        let recent = RecentRepos.shared.urls.filter { !openPaths.contains($0.path) }
        var entries: [MenuEntry] = repoTabs.map { tab in
            .action(tab.repoURL?.lastPathComponent ?? tab.title, checked: tab.id == model.selectedTabID) { [model] in
                model.selectTab(id: tab.id)
            }
        }
        if !recent.isEmpty {
            entries += [.separator, .action(Self.recentMarker, enabled: false) {}]
            entries += recent.map { url in .action(url.lastPathComponent) { [model] in model.openTab(url) } }
        }
        entries += [.separator, .action("Open…") {
            NSApp.sendAction(#selector(AppDelegate.openDocument(_:)), to: nil, from: nil)
        }]
        if let session = model.actionSession { entries += [.separator] + RepoMenus.repository(session) }
        return entries
    }
}

// MARK: - Dropdown

/// A toolbar pull-down at a fixed width (the repo and branch menus): an icon, the title cut with "…" at the end, and
/// the chevron, in the same capsule as the menu items beside it. Its width never follows the title, so the toolbar
/// never shifts between tabs or branches. The menu is filled when it opens (the toolbar's `menuNeedsUpdate`); when
/// the item is in the overflow menu, `overflowMenu` is filled from the same entries.
@MainActor
private final class ToolbarDropdown {
    /// The space between the icon and the title: transparent room at the icon's trailing side, so the button's own
    /// layout (and the `chrome` measured from it) includes it.
    static let iconGap: CGFloat = 4
    /// The arrow's point size, its space from the button's trailing edge, and the least space between it and the
    /// title. AppKit's own arrow is smaller and has no gap or size to set, so it is hidden and this one is drawn.
    static let chevronSize: CGFloat = 11
    static let chevronInset: CGFloat = 11
    static let chevronGap: CGFloat = 8

    let item: NSToolbarItem
    let button = WindowAwarePopUpButton(frame: .zero, pullsDown: true)
    /// The menu the button pulls down. A pull-down shows its first item as the button's title and never lists it,
    /// so `menuNeedsUpdate` keeps `titleItem` first.
    let menu = NSMenu()
    let titleItem = NSMenuItem()
    /// The submenu of the item's overflow form.
    let overflowMenu = NSMenu()
    /// nil: as wide as the title, never cut.
    private let width: CGFloat?
    /// The button's width beside its title (icon, chevron, insets), measured once it is in the toolbar.
    private var chrome: CGFloat?
    private let chevron = ToolbarChevron()

    init(_ id: NSToolbarItem.Identifier, label: String, width: CGFloat?, image: NSImage?) {
        self.width = width
        item = NSToolbarItem(itemIdentifier: id)
        item.label = label
        item.paletteLabel = label
        // Kept out of the overflow menu longer than the buttons.
        item.visibilityPriority = .high
        // Its state is set from the model, never validated by AppKit.
        item.autovalidates = false

        for menu in [menu, overflowMenu] { menu.autoenablesItems = false }
        // A template image, so it takes the toolbar's text color.
        titleItem.image = image.map(Self.padded)
        menu.items = [titleItem]
        button.menu = menu
        button.bezelStyle = .toolbar
        (button.cell as? NSPopUpButtonCell)?.arrowPosition = .noArrow
        button.addSubview(chevron)
        NSLayoutConstraint.activate([
            chevron.trailingAnchor.constraint(equalTo: button.trailingAnchor, constant: -Self.chevronInset),
            chevron.centerYAnchor.constraint(equalTo: button.centerYAnchor),
        ])
        button.imagePosition = .imageLeading
        button.usesSingleLineMode = true
        button.lineBreakMode = .byTruncatingTail
        button.translatesAutoresizingMaskIntoConstraints = false
        if let width { button.widthAnchor.constraint(equalToConstant: width).isActive = true }
        button.trailingRoom = Self.chevronGap + chevron.intrinsicContentSize.width
        button.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        button.setAccessibilityLabel(label)
        button.didMoveToWindow = { [weak self] in self?.fitTitle() }
        item.view = button

        let form = NSMenuItem(title: label, action: nil, keyEquivalent: "")
        form.image = image
        form.submenu = overflowMenu
        item.menuFormRepresentation = form
    }

    // Each setter writes only a changed value: an unchanged write still relayouts the toolbar.

    /// The full title (the overflow menu shows it); the button shows it cut to its width.
    var title = "" {
        didSet {
            guard title != oldValue else { return }
            item.menuFormRepresentation?.title = title
            fitTitle()
        }
    }

    var toolTip: String? {
        get { button.toolTip }
        set { if button.toolTip != newValue { button.toolTip = newValue } }
    }

    /// An image drawn as given before the title (the profile chip's color dot), unlike the template icon of `init`.
    var image: NSImage? {
        get { titleItem.image }
        set {
            titleItem.image = newValue
            item.menuFormRepresentation?.image = newValue
            button.synchronizeTitleAndSelectedItem()
            if width == nil { button.invalidateIntrinsicContentSize() }
        }
    }

    var isEnabled: Bool {
        get { button.isEnabled }
        set {
            guard button.isEnabled != newValue else { return }
            button.isEnabled = newValue
            chevron.isEnabled = newValue
            item.isEnabled = newValue
            item.menuFormRepresentation?.isEnabled = newValue && !blocksInteraction
        }
    }

    /// The button looks as it is but ignores clicks, and its overflow entry is disabled (the onboarding's hold).
    var blocksInteraction = false {
        didSet {
            guard blocksInteraction != oldValue else { return }
            button.blocksInteraction = blocksInteraction
            item.menuFormRepresentation?.isEnabled = isEnabled && !blocksInteraction
        }
    }

    /// Shows `title` cut with "…" to fit on one line. On macOS 26 a pull-down draws its title with SwiftUI, which
    /// wraps a long one onto two lines whatever the button's line break mode, so the cut is measured here. Before
    /// the button is in the toolbar (another control size) the full title shows.
    private func fitTitle() {
        let font = button.font ?? .systemFont(ofSize: NSFont.systemFontSize)
        let attributes: [NSAttributedString.Key: Any] = [.font: font]
        func textWidth(_ text: String) -> CGFloat { (text as NSString).size(withAttributes: attributes).width }
        var shown = title
        if button.window != nil, let width {
            // Measured while the menu holds only the title item (it is filled on open), which a pull-down's size
            // also follows.
            if chrome == nil, menu.items.count == 1 {
                chrome = (button.cell?.cellSize.width ?? 0) - textWidth(titleItem.title)
                    + Self.chevronGap + chevron.intrinsicContentSize.width
            }
            if let chrome { shown = Self.cut(title, toWidth: width - chrome, measure: textWidth) }
        }
        guard titleItem.title != shown else { return }
        titleItem.title = shown
        button.synchronizeTitleAndSelectedItem()
        // Without a fixed width, the toolbar sizes the button to its new title.
        if width == nil { button.invalidateIntrinsicContentSize() }
    }

    /// `image` with `iconGap` of transparent space after it, still a template. A symbol is drawn at the large scale
    /// the toolbar's pull-down gave it (the padded image is no symbol any more, so the button no longer scales it).
    static func padded(_ image: NSImage) -> NSImage {
        let image = image.withSymbolConfiguration(NSImage.SymbolConfiguration(scale: .large)) ?? image
        let size = image.size
        let padded = NSImage(size: NSSize(width: size.width + iconGap, height: size.height), flipped: false) { _ in
            image.draw(in: NSRect(origin: .zero, size: size))
            return true
        }
        padded.isTemplate = true
        padded.accessibilityDescription = image.accessibilityDescription
        return padded
    }

    /// `text`, or its longest prefix plus "…" whose width is at most `limit`.
    private static func cut(_ text: String, toWidth limit: CGFloat, measure: (String) -> CGFloat) -> String {
        guard measure(text) > limit else { return text }
        let characters = Array(text)
        var low = 0, high = characters.count - 1
        while low < high {
            let middle = (low + high + 1) / 2
            if measure(String(characters[..<middle]) + "…") <= limit { low = middle } else { high = middle - 1 }
        }
        return String(characters[..<low]) + "…"
    }
}

/// The arrow of a toolbar pull-down, drawn over its button: clicks go through it to the button. The toolbar draws it
/// in its own label color whatever its tint, so it is dimmed by its opacity instead, to the dimmed title's gray, when
/// the button is disabled or its window is not the main one of the active app.
final class ToolbarChevron: NSImageView {
    /// Its opacity when dimmed: measured to match the title of an inactive window over the button's fill.
    static let dimmedAlpha: CGFloat = 0.4
    private var observers: [NSObjectProtocol] = []

    init() {
        super.init(frame: .zero)
        let configuration = NSImage.SymbolConfiguration(pointSize: ToolbarDropdown.chevronSize, weight: .semibold)
        image = NSImage(systemSymbolName: "chevron.down", accessibilityDescription: nil)?
            .withSymbolConfiguration(configuration)
        translatesAutoresizingMaskIntoConstraints = false
        setAccessibilityElement(false)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError() }

    override var isEnabled: Bool {
        didSet { updateDimming() }
    }

    override func hitTest(_ point: NSPoint) -> NSView? { nil }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        observers.forEach(NotificationCenter.default.removeObserver)
        observers = observeMainState(of: window) { [weak self] in self?.updateDimming() }
        updateDimming()
    }

    private func updateDimming() {
        alphaValue = isEnabled && isMainState(window) ? 1 : Self.dimmedAlpha
    }
}

/// Whether `window` shows as active: the main window of the active app (true before the view is in one).
@MainActor private func isMainState(_ window: NSWindow?) -> Bool {
    NSApp.isActive && window?.isMainWindow ?? true
}

/// Calls `update` each time `window` becomes or stops being the main window, or the app active; the previous
/// observers, if any, are to be removed first. None without a window (a nil object would observe every window).
@MainActor private func observeMainState(of window: NSWindow?, _ update: @escaping @MainActor () -> Void)
    -> [NSObjectProtocol]
{
    guard let window else { return [] }
    let names: [(Notification.Name, AnyObject)] = [
        (NSWindow.didBecomeMainNotification, window), (NSWindow.didResignMainNotification, window),
        (NSApplication.didBecomeActiveNotification, NSApp), (NSApplication.didResignActiveNotification, NSApp),
    ]
    return names.map { name, object in
        NotificationCenter.default.addObserver(forName: name, object: object, queue: .main) { _ in
            MainActor.assumeIsolated { update() }
        }
    }
}

/// A toolbar icon button with its own hover, on macOS 26: a circle inside the capsule, as EchoDiar's toolbar buttons.
/// AppKit's own highlight fills the whole capsule of an item alone in it (Fetch), and in a group its size differs from
/// button to button, some nearly as big as the capsule. It stands for a button item (`HeaderToolbar.hoverButton`), which sets its image,
/// state and tooltip; `menuForm` is its entry in the overflow menu.
private final class ToolbarHoverButton: NSView {
    /// Every button's width, alone (Fetch), in a row (`HeaderToolbar.row`) or in Pull ▾ / Push ▾: the circles of
    /// buttons side by side are 4 pt apart.
    private static let width: CGFloat = 32
    private static let height: CGFloat = 24
    private static let highlightDiameter: CGFloat = 28
    /// The room `capsule` adds at both ends. AppKit pads an item view less on the sides than above and below: a lone
    /// button 36 wide makes its capsule round, and leaves the same room around the circle at a capsule's ends as
    /// above and below it. A capsule of several buttons gets more, so its ends are roomier than its top and bottom.
    private static let endInset: CGFloat = 2
    private static let groupEndInset: CGFloat = 4

    /// One capsule's view: `buttons` side by side, `spacing` apart (negative brings them closer than their circles'
    /// 4 pt), with `endInset` (or `groupEndInset`) at both ends.
    static func capsule(_ buttons: [ToolbarHoverButton], spacing: CGFloat = 0) -> NSStackView {
        let stack = NSStackView(views: buttons)
        stack.spacing = spacing
        let inset = buttons.count > 1 ? groupEndInset : endInset
        stack.edgeInsets = NSEdgeInsets(top: 0, left: inset, bottom: 0, right: inset)
        return stack
    }

    private let button = PressReportingButton()
    let menuForm: NSMenuItem
    private let highlight = NSView()
    private var isHovered = false { didSet { updateHighlight() } }
    private var observers: [NSObjectProtocol] = []

    init(target: AnyObject, action: Selector?, label: String) {
        let width = Self.width, diameter = Self.highlightDiameter
        menuForm = NSMenuItem(title: label, action: action, keyEquivalent: "")
        menuForm.target = target
        super.init(frame: NSRect(x: 0, y: 0, width: width, height: Self.height))
        translatesAutoresizingMaskIntoConstraints = false
        NSLayoutConstraint.activate([
            widthAnchor.constraint(equalToConstant: width),
            heightAnchor.constraint(equalToConstant: Self.height),
        ])

        highlight.wantsLayer = true
        highlight.layer?.cornerRadius = diameter / 2
        highlight.frame = NSRect(x: (width - diameter) / 2, y: (Self.height - diameter) / 2,
                                 width: diameter, height: diameter)
        addSubview(highlight)

        button.isBordered = false
        button.imagePosition = .imageOnly
        button.imageScaling = .scaleNone
        button.target = target
        button.action = action
        button.setAccessibilityLabel(label)
        button.frame = bounds
        button.autoresizingMask = [.width, .height]
        button.didChangePress = { [weak self] in self?.updateHighlight() }
        addSubview(button)
        updateHighlight()
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError() }

    /// The 28 pt circle overflows the 24 pt high view, inside the capsule.
    override var wantsDefaultClipping: Bool { false }

    var image: NSImage? {
        get { button.image }
        set {
            button.image = newValue.map { $0.withSymbolConfiguration(symbolConfiguration) ?? $0 }
            menuForm.image = newValue
        }
    }

    /// The icon's color (the Update button's green); the label color when nil.
    var iconColor: NSColor? {
        didSet { updateHighlight() }
    }

    var isEnabled: Bool {
        get { button.isEnabled }
        set {
            button.isEnabled = newValue
            menuForm.isEnabled = newValue && !blocksInteraction
            updateHighlight()
        }
    }

    /// Drawn as it is (enabled or not) but takes no click and shows no hover, and its overflow entry is disabled (the
    /// onboarding's hold).
    var blocksInteraction = false {
        didSet {
            guard blocksInteraction != oldValue else { return }
            button.blocksInteraction = blocksInteraction
            menuForm.isEnabled = button.isEnabled && !blocksInteraction
            updateHighlight()
        }
    }

    /// When set, a press shows this menu under the button, on mouse down as a pull-down does, in place of an action.
    var dropdownMenu: NSMenu? {
        didSet {
            button.target = self
            button.action = #selector(showDropdownMenu)
            button.sendAction(on: .leftMouseDown)
        }
    }

    @objc private func showDropdownMenu() {
        // Below the capsule, which reaches about 6 pt under the view.
        dropdownMenu?.popUp(positioning: nil, at: NSPoint(x: 0, y: -6), in: self)
    }

    /// The scale AppKit draws a bordered toolbar item's symbol at; set before `image`.
    var symbolConfiguration = NSImage.SymbolConfiguration(scale: .large)

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        trackingAreas.forEach(removeTrackingArea)
        addTrackingArea(NSTrackingArea(rect: bounds, options: [.mouseEnteredAndExited, .activeAlways, .inVisibleRect],
                                       owner: self))
    }

    override func mouseEntered(with event: NSEvent) { isHovered = true }
    override func mouseExited(with event: NSEvent) { isHovered = false }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        if window == nil { isHovered = false }
        observers.forEach(NotificationCenter.default.removeObserver)
        observers = observeMainState(of: window) { [weak self] in self?.updateHighlight() }
        updateHighlight()
    }

    private func updateHighlight() {
        let color: NSColor? = !button.isEnabled || blocksInteraction ? nil
            : button.isPressed ? .white.withAlphaComponent(0.2)
            : isHovered ? .white.withAlphaComponent(0.1) : nil
        highlight.layer?.backgroundColor = color?.cgColor
        // A borderless button draws its template image in a secondary gray; the toolbar's icons are the label color,
        // dimmed in an inactive window as AppKit's buttons beside it (and the dropdowns' `ToolbarChevron`).
        button.contentTintColor = button.isEnabled ? iconColor ?? .labelColor : .tertiaryLabelColor
        button.alphaValue = !button.isEnabled || isMainState(window) ? 1 : ToolbarChevron.dimmedAlpha
    }
}

/// A borderless button that reports while it is pressed (its tracking loop runs inside `mouseDown`).
private final class PressReportingButton: NSButton {
    var didChangePress: (() -> Void)?
    private(set) var isPressed = false
    /// Swallows clicks (not passed on, so the title bar never drags the window or zooms it).
    var blocksInteraction = false

    override func mouseDown(with event: NSEvent) {
        guard !blocksInteraction else { return }
        isPressed = true
        didChangePress?()
        super.mouseDown(with: event)
        isPressed = false
        didChangePress?()
    }
}

/// A pull-down that reports its move into a window, where the toolbar has set its control size.
final class WindowAwarePopUpButton: NSPopUpButton {
    var didMoveToWindow: (() -> Void)?
    /// Room after the title for the arrow drawn over the button (`ToolbarChevron`), which AppKit does not count.
    var trailingRoom: CGFloat = 0
    /// Swallows clicks (not passed on, so the title bar never drags the window or zooms it).
    var blocksInteraction = false

    override func mouseDown(with event: NSEvent) {
        guard !blocksInteraction else { return }
        super.mouseDown(with: event)
    }

    override var intrinsicContentSize: NSSize {
        var size = super.intrinsicContentSize
        size.width += trailingRoom
        return size
    }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        if window != nil { didMoveToWindow?() }
    }
}

// MARK: - Repo actions

/// A repo action of the toolbar's buttons; the command palette lists the same actions (`PaletteCommands`).
enum ToolbarAction: CaseIterable {
    case pull, push, fetch, branch, stash, pop

    var key: ActionBarAction {
        switch self {
        case .pull: .pull
        case .push: .push
        case .fetch: .fetch
        case .branch: .branch
        case .stash: .stash
        case .pop: .pop
        }
    }

    var title: String {
        switch self {
        case .pull: "Pull"
        case .push: "Push"
        case .fetch: "Fetch"
        case .branch: "Branch"
        case .stash: "Stash"
        case .pop: "Pop"
        }
    }

    var systemImage: String {
        switch self {
        case .pull: "arrow.down.to.line"
        case .push: "arrow.up.to.line"
        case .fetch: "arrow.triangle.2.circlepath"
        case .branch: "lucide-git-branch"
        case .stash: "tray.and.arrow.down"
        case .pop: "tray.and.arrow.up"
        }
    }

    @MainActor func help(_ session: RepoSession) -> String {
        switch self {
        case .pull: "Pull the current branch"
        case .push: session.currentBranch.flatMap(session.pushTarget(of:)) == nil
            ? "Add a remote to push" : "Push the current branch"
        case .fetch: "Fetch all remotes"
        case .branch: "Create a branch at HEAD"
        case .stash: "Stash every change"
        case .pop: session.newestStash.map { "Pop \($0.selector): \($0.message)" } ?? "No stash to pop"
        }
    }

    @MainActor func isEnabled(_ session: RepoSession) -> Bool {
        switch self {
        case .pull: session.currentBranch != nil
        case .push: session.currentBranch.flatMap(session.pushTarget(of:)) != nil
        case .fetch: true
        case .branch: session.refs.value?.head.commit != nil
        case .stash: !(session.status.value?.entries.isEmpty ?? true)
        case .pop: session.newestStash != nil
        }
    }

    @MainActor func perform(_ session: RepoSession) {
        switch self {
        case .pull: session.pull(RepoSession.preferredPullMode)
        case .push: if let branch = session.currentBranch { session.push(branch: branch, key: .push) }
        case .fetch: session.fetchAll()
        case .branch: session.createBranchAtHead()
        case .stash: session.stashAll()
        case .pop: session.popNewestStash()
        }
    }
}
