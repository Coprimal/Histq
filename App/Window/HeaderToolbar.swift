// The window's toolbar, in the traffic-light row (house style, as EchoDiar and SegDown): at the leading edge the repo
// menu (the window's repo tabs, recent repos, Open…), the branch menu (checks out the picked branch), as in GitKraken,
// and the tab's profile chip (`ProfilePicker`); at the trailing edge capsules of Undo / Redo, Pull ▾ / Push ▾ / Fetch, Branch / Stash / Pop, then
// Terminal / Search / Settings. The set of items never changes: on a Welcome tab or About the repo actions are
// disabled, not removed. Settings is a modal over the tab (task 9.7), so the repo items stay as they are under it.
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
    /// The color the profile chip's dot shows ("" for no profile), so the image is only redrawn when it changes.
    private var profileDot: String?
    /// The space between the profile chip's dot and its title.
    private static let profileDotGap: CGFloat = 5
    private let undoItem = NSToolbarItem(itemIdentifier: ID.undo)
    private let redoItem = NSToolbarItem(itemIdentifier: ID.redo)
    private let pullItem = NSMenuToolbarItem(itemIdentifier: ID.pull)
    private let pushItem = NSMenuToolbarItem(itemIdentifier: ID.push)
    private let fetchItem = NSToolbarItem(itemIdentifier: ID.fetch)
    private let createBranchItem = NSToolbarItem(itemIdentifier: ID.createBranch)
    private let stashItem = NSToolbarItem(itemIdentifier: ID.stash)
    private let popItem = NSToolbarItem(itemIdentifier: ID.pop)
    private let terminalItem = NSToolbarItem(itemIdentifier: ID.terminal)
    private let searchItem = NSToolbarItem(itemIdentifier: ID.search)
    private let settingsItem = NSToolbarItem(itemIdentifier: ID.settings)
    private var groups: [NSToolbarItem.Identifier: NSToolbarItemGroup] = [:]

    /// The repo actions' buttons, by the operation each shows.
    private var actionItems: [(item: NSToolbarItem, action: ToolbarAction)] {
        [(pullItem, .pull), (pushItem, .push), (fetchItem, .fetch), (createBranchItem, .branch), (stashItem, .stash),
         (popItem, .pop)]
    }

    private enum ID {
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
        static let terminal = NSToolbarItem.Identifier("terminal")
        static let search = NSToolbarItem.Identifier("search")
        static let settings = NSToolbarItem.Identifier("settings")
        static let historyGroup = NSToolbarItem.Identifier("historyGroup")
        static let syncGroup = NSToolbarItem.Identifier("syncGroup")
        static let branchGroup = NSToolbarItem.Identifier("branchGroup")
        static let toolsGroup = NSToolbarItem.Identifier("toolsGroup")
    }

    init(model: WindowModel) {
        self.model = model
        super.init()
        configureItems()
        toolbar.delegate = self
        toolbar.displayMode = .iconOnly
        toolbar.allowsUserCustomization = false
        observe()
    }

    // MARK: Items

    private func configureItems() {
        for dropdown in [repoItem, branchItem, profileItem] {
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
        configureButton(searchItem, label: "Search", systemImage: "magnifyingglass")
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

        groups[ID.historyGroup] = group(ID.historyGroup, [undoItem, redoItem])
        groups[ID.syncGroup] = group(ID.syncGroup, [pullItem, pushItem, fetchItem])
        groups[ID.branchGroup] = group(ID.branchGroup, [createBranchItem, stashItem, popItem])
        groups[ID.toolsGroup] = group(ID.toolsGroup, [terminalItem, searchItem, settingsItem])
    }

    /// A menu whose items are built when it opens (`menuNeedsUpdate`), never on a model change.
    private func makeMenu() -> NSMenu {
        let menu = NSMenu()
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
        return [ID.repo, ID.branch, ID.profile, .flexibleSpace, ID.historyGroup] + gap + [ID.syncGroup] + gap + [ID.branchGroup]
            + gap + [ID.toolsGroup]
    }

    func toolbarAllowedItemIdentifiers(_ toolbar: NSToolbar) -> [NSToolbarItem.Identifier] {
        toolbarDefaultItemIdentifiers(toolbar)
    }

    func toolbar(_ toolbar: NSToolbar, itemForItemIdentifier itemIdentifier: NSToolbarItem.Identifier,
                 willBeInsertedIntoToolbar flag: Bool) -> NSToolbarItem?
    {
        switch itemIdentifier {
        case ID.repo: repoItem.item
        case ID.branch: branchItem.item
        case ID.profile: profileItem.item
        default: groups[itemIdentifier]
        }
    }

    // MARK: State

    /// Applies the model to the items, then applies it again after the next change of what it read. Only the
    /// selected tab's title, its session's refs, running operations, status, stashes, remotes, profile, undo status,
    /// operation in progress and terminal drawer, the profile store, the page and the Settings modal are read, so
    /// other tabs and the content's own state never wake the toolbar.
    private func observe() {
        withObservationTracking {
            apply()
        } onChange: { [weak self] in
            // Called before the change lands, off any isolation: apply on the main actor once it has.
            Task { @MainActor [weak self] in self?.observe() }
        }
    }

    private func apply() {
        let selected = model.selectedIndex.map { model.tabs[$0] }
        let session = model.actionSession
        repoItem.title = selected?.repoURL == nil ? "Histq" : selected?.title ?? "Histq"
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
            let title = Self.branchTitle(session.refs.value?.head)
            branchItem.title = title
            branchItem.isEnabled = !isBusy && session.refs.value != nil
            // The full name, as the title may be cut.
            branchItem.toolTip = isBusy ? "Checking out…" : "\(title): check out another branch"
        }

        // Hidden, like the branch menu, where no repo tab shows (Welcome, About).
        set(profileItem.item, hidden: session == nil)
        if let session {
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
        #if DEBUG
        logItemFrames()
        #endif
    }

    // Each setter writes only a changed value: an unchanged write still relayouts the toolbar.

    private func set(_ item: NSToolbarItem, title: String) {
        if item.title != title { item.title = title }
    }

    private func set(_ item: NSToolbarItem, enabled: Bool) {
        if item.isEnabled != enabled { item.isEnabled = enabled }
    }

    private func set(_ item: NSToolbarItem, toolTip: String) {
        if item.toolTip != toolTip { item.toolTip = toolTip }
    }

    private func set(_ item: NSToolbarItem, hidden: Bool) {
        if item.isHidden != hidden { item.isHidden = hidden }
    }

    private var symbols: [ObjectIdentifier: String] = [:]

    private func set(_ item: NSToolbarItem, systemImage: String, label: String) {
        guard symbols[ObjectIdentifier(item)] != systemImage else { return }
        symbols[ObjectIdentifier(item)] = systemImage
        // A symbol this system lacks keeps the current icon rather than an empty button.
        if let image = NSImage.icon(systemImage, accessibilityDescription: label, size: 20) { item.image = image }
    }

    /// In place of a running action's icon (there is no spinner in a toolbar button without a custom view).
    private static let busySymbol = "progress.indicator"
    private static let undoSymbol = "arrow.uturn.backward"
    private static let redoSymbol = "arrow.uturn.forward"

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
            guard let self, repoItem.button.window != nil else { return }
            let frames = [("repo", repoItem), ("branch", branchItem)].map { name, dropdown in
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
    @objc private func undo(_ sender: Any?) { model.actionSession?.undo() }
    @objc private func redo(_ sender: Any?) { model.actionSession?.redo() }

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
        guard let session = model.actionSession else { return }
        action.perform(session)
    }

    @objc private func toggleSettings(_ sender: Any?) {
        model.toggleSettings()
    }

    @objc private func toggleTerminal(_ sender: Any?) {
        model.toggleTerminal()
    }

    @objc private func togglePalette(_ sender: Any?) {
        model.togglePalette()
    }

    // MARK: Menus

    func menuNeedsUpdate(_ menu: NSMenu) {
        let entries: [MenuEntry] = switch menu {
        case repoItem.menu, repoItem.overflowMenu: repoEntries()
        case branchItem.menu, branchItem.overflowMenu: model.actionSession.map(RepoMenus.branchPicker) ?? []
        case profileItem.menu, profileItem.overflowMenu:
            model.actionSession.map { ProfilePicker.entries(session: $0, model: model) } ?? []
        case pullItem.menu: model.actionSession.map(RepoMenus.pull) ?? []
        case pushItem.menu: model.actionSession.map(RepoMenus.push) ?? []
        default: []
        }
        let built = MenuBuilder.menu(entries)
        // Before the title item is put first: it pairs the menu's first items with the profiles.
        if menu === profileItem.menu || menu === profileItem.overflowMenu { ProfilePicker.decorate(built) }
        var items = built.items
        built.removeAllItems()
        if menu === repoItem.menu || menu === repoItem.overflowMenu,
           let index = items.firstIndex(where: { $0.title == Self.recentMarker })
        {
            // The recent repos under a section header.
            items[index] = NSMenuItem.sectionHeader(title: "Recent")
        }
        if let dropdown = [repoItem, branchItem, profileItem].first(where: { $0.menu === menu }) {
            menu.items = [dropdown.titleItem] + items
        } else {
            menu.items = items
        }
    }

    /// Stands for the "Recent" section header in `repoEntries`, which `MenuEntry` cannot express.
    private static let recentMarker = "\u{1}recent"

    /// The window's repo tabs (the selected one checked; a pick selects that tab at once, as a click on it does), the
    /// recent repos not open here (a pick opens it as `openTab`), then Open….
    private func repoEntries() -> [MenuEntry] {
        let repoTabs = model.tabs.filter { $0.repoURL != nil }
        let openPaths = Set(repoTabs.compactMap { $0.repoURL?.path })
        let recent = RecentRepos.shared.urls.filter { !openPaths.contains($0.path) }
        var entries: [MenuEntry] = repoTabs.map { tab in
            .action(tab.title, checked: tab.id == model.selectedTabID) { [model] in model.selectTab(id: tab.id) }
        }
        if !recent.isEmpty {
            entries += [.separator, .action(Self.recentMarker, enabled: false) {}]
            entries += recent.map { url in .action(url.lastPathComponent) { [model] in model.openTab(url) } }
        }
        entries += [.separator, .action("Open…") {
            NSApp.sendAction(#selector(AppDelegate.openDocument(_:)), to: nil, from: nil)
        }]
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
            item.menuFormRepresentation?.isEnabled = newValue
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
    private static func padded(_ image: NSImage) -> NSImage {
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
    private static let dimmedAlpha: CGFloat = 0.4
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
        // A nil object would observe every window.
        guard let window else { observers = []; return }
        let names: [(Notification.Name, AnyObject)] = [
            (NSWindow.didBecomeMainNotification, window), (NSWindow.didResignMainNotification, window),
            (NSApplication.didBecomeActiveNotification, NSApp), (NSApplication.didResignActiveNotification, NSApp),
        ]
        observers = names.map { name, object in
            NotificationCenter.default.addObserver(forName: name, object: object, queue: .main) { [weak self] _ in
                MainActor.assumeIsolated { self?.updateDimming() }
            }
        }
        updateDimming()
    }

    private func updateDimming() {
        let isActive = NSApp.isActive && window?.isMainWindow ?? true
        alphaValue = isEnabled && isActive ? 1 : Self.dimmedAlpha
    }
}

/// A pull-down that reports its move into a window, where the toolbar has set its control size.
final class WindowAwarePopUpButton: NSPopUpButton {
    var didMoveToWindow: (() -> Void)?
    /// Room after the title for the arrow drawn over the button (`ToolbarChevron`), which AppKit does not count.
    var trailingRoom: CGFloat = 0

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
