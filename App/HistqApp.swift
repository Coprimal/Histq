// The app entry: an AppKit delegate that owns the windows, their tabs, the main menu and the open handling.
import AppKit
import SwiftUI

/// AppKit entry point: no SwiftUI `App`, so SwiftUI is only loaded inside the windows.
@main
@MainActor
enum HistqApp {
    // NSApplication.delegate is weak; keep the delegate alive for the app lifetime.
    private static let delegate = AppDelegate()

    static func main() {
        UITiming.markLaunch()
        // Start resolving git and the login shell's PATH (seconds, for writes) before the first repo needs them.
        GitToolchain.prepare()
        StatePaths.prepare()
        // Read the last session off the main thread now; a launch without folders restores it.
        SessionStore.startLoading()
        Preferences.registerDefaults()
        // Read the profiles off the main thread now, so a repo opened later finds its profile in memory.
        ProfileLibrary.shared.loadIfNeeded()
        #if DEBUG
        KeychainSelfTest.runIfAsked()
        #endif
        let app = NSApplication.shared
        app.delegate = delegate
        app.run()
    }
}

/// Whether a window shows on screen (not hidden, minimized or covered). Read it with
/// `@Environment(WindowState.self)` to pause timelines and pulses nobody sees.
@Observable
@MainActor
final class WindowState {
    var isVisible = true
}

/// Owns the windows, one `WindowModel` each, and the main menu for the app lifetime.
@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate, NSWindowDelegate, NSMenuItemValidation {
    /// A window with its tabs, visibility and toolbar.
    private final class Entry {
        let window: NSWindow
        let model: WindowModel
        let state: WindowState
        /// The toolbar's delegate and items' target, which the toolbar does not retain.
        let toolbar: HeaderToolbar
        /// Native tab group changes (Merge All Windows, a tab dragged out), which save the session.
        var tabGroupObservation: NSKeyValueObservation?

        init(window: NSWindow, model: WindowModel, state: WindowState, toolbar: HeaderToolbar) {
            self.window = window
            self.model = model
            self.state = state
            self.toolbar = toolbar
        }
    }

    private var entries: [Entry] = []
    /// The tab position the windows' minimum sizes were last set for.
    private var tabPosition = TabPosition.current
    /// Sparkle; stays off (menu item disabled) while `SUPublicEDKey` is empty.
    private let updater = Updater()

    func applicationWillFinishLaunching(_ notification: Notification) {
        // Histq is dark mode only, whatever the system's appearance.
        NSApp.appearance = NSAppearance(named: .darkAqua)
        NSApp.mainMenu = makeMainMenu()
        // General › Tab position moves the tabs into panel 0, which the minimum width counts. Posted for every key,
        // possibly off the main thread; only a change of the position re-clamps.
        NotificationCenter.default.addObserver(
            forName: UserDefaults.didChangeNotification, object: Preferences.defaults, queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated { self?.preferencesChanged() }
        }
    }

    private func preferencesChanged() {
        let position = TabPosition.current
        guard position != tabPosition else { return }
        tabPosition = position
        for entry in entries { WindowSizing.clampMinimum(of: entry.window) }
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        // Tooltips (`.help`) after 0.25 s instead of the system's 1.5 s, as in EchoDiar.
        UserDefaults.standard.register(defaults: ["NSInitialToolTipDelay": 250])
        updater.start()
        // Folders given at launch (`open -a Histq <repo>`) arrive in `application(_:open:)` first and already made
        // the window: they are what this launch shows. Without any, the last session comes back once read.
        guard entries.isEmpty else { return finishLaunching() }
        Task { @MainActor in
            await self.restoreLastSession()
            self.finishLaunching()
        }
    }

    /// The launch's windows are open: capture starts (saving them now, so a launch with folders is restorable too),
    /// then the DEBUG `-HistqSelect` request.
    private func finishLaunching() {
        SessionStore.start { [unowned self] in self.currentSession() }
        SessionStore.schedule()
        if let request = AppState.launchSelection {
            // Next turn, once the launch's folders are open as tabs.
            Task { @MainActor in self.target()?.model.select(request) }
        }
        #if DEBUG
        if ProcessInfo.processInfo.arguments.contains("-HistqOpenPalette") {
            Task { @MainActor in await self.debugOpenPalette() }
        }
        if let spec = AppState.launchFind {
            Task { @MainActor in await self.debugFind(spec) }
        }
        if let row = AppState.launchDoubleClick, AppState.isStateDirMode {
            // The click monitor only with the seam, so other QA runs' timing.log keeps only its own lines.
            DoubleClickProbe.install()
            // Once the window is up and laid out.
            Task { @MainActor in
                try? await Task.sleep(for: .seconds(1.5))
                guard let window = self.target()?.window else { return }
                await DoubleClickProbe.run(row, in: window)
            }
        }
        #endif
    }

    #if DEBUG
    /// DEBUG `-HistqOpenPalette "<query>"` (QA of the command palette): once the selected repo tab's refs, status and
    /// log are read (the palette copies its rows when it opens), opens the front window's palette with `query` typed.
    /// With `-HistqPaletteRun` it then runs the first row as Return does, once ranked; a confirmation the row asks is
    /// accepted (as `-HistqRun` does) and the outcome goes to `operations.txt`. For QA on fixture copies only.
    private func debugOpenPalette() async {
        let value = AppState.launchFlag("-HistqOpenPalette") ?? ""
        // An empty query may not reach the app as an argument: the next flag is then not the query.
        let query = value.hasPrefix("-Histq") ? "" : value
        for _ in 0..<200 {
            guard let model = target()?.model else { return }
            let session = model.selectedSession
            let isRepoTab = model.selectedIndex.map { model.tabs[$0].repoURL != nil && !model.tabs[$0].isMissing } ?? false
            if !isRepoTab || (session?.refs.value != nil && session?.status.value != nil && session?.log.value != nil) {
                break
            }
            try? await Task.sleep(for: .milliseconds(50))
        }
        guard let model = target()?.model else { return }
        model.openPalette(query: query)
        guard ProcessInfo.processInfo.arguments.contains("-HistqPaletteRun"), let palette = model.palette else { return }
        for _ in 0..<250 {
            if palette.isRankFresh { break }
            try? await Task.sleep(for: .milliseconds(20))
        }
        guard let item = palette.ranked.first else { return RepoMenus.debugLog("palette: no row for \(query)") }
        let session = model.actionSession
        guard model.performPalette(item) else { return RepoMenus.debugLog("palette: \(item.title) cannot run") }
        if let session, let confirmation = session.confirmation {
            session.confirmation = nil
            session.run(confirmation.write, title: confirmation.operation, key: confirmation.key)
        }
        while session?.running.isEmpty == false { try? await Task.sleep(for: .milliseconds(50)) }
        RepoMenus.debugLog(session?.failure.map { "fail palette \(item.title): \($0.message)" }
            ?? "ok palette \(item.title)")
    }
    #endif

    #if DEBUG
    /// DEBUG `-HistqFind "<query>[;next|prev…]"` (QA of the graph search): once the front repo tab's whole log is read,
    /// opens its search through `findCommits` (the menu's path), types the query a character at a time (120 ms apart,
    /// a fast typist), waits for its result, then runs each step 300 ms apart. `GraphSearch` logs a `find-key` line
    /// per keystroke and a `find …` line per result and step.
    private func debugFind(_ spec: String) async {
        let parts = spec.split(separator: ";", omittingEmptySubsequences: false).map(String.init)
        let early = AppState.launchFindEarly
        for _ in 0..<1200 {
            if let log = target()?.model.actionSession?.log.value, early || log.isComplete { break }
            try? await Task.sleep(for: .milliseconds(early ? 5 : 50))
        }
        // The graph's first layout.
        if !early { try? await Task.sleep(for: .milliseconds(500)) }
        findCommits(nil)
        guard let search = target()?.model.actionSession?.graphSearch, search.isOpen else {
            return UITiming.find("\(spec) cannot open")
        }
        var typed = ""
        if early { search.query = parts.first ?? "" }
        for character in early ? "" : parts.first ?? "" {
            typed.append(character)
            search.query = typed
            try? await Task.sleep(for: .milliseconds(120))
        }
        for _ in 0..<100 {
            if search.isFresh { break }
            try? await Task.sleep(for: .milliseconds(20))
        }
        for step in parts.dropFirst() {
            try? await Task.sleep(for: .milliseconds(300))
            switch step {
            case "next": search.next()
            case "prev": search.previous()
            default: UITiming.find("\(step) unknown step")
            }
        }
    }
    #endif

    /// Quit saves the session while the windows are still open; the windows closing after it save nothing.
    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        SessionStore.saveForQuit()
        return .terminateNow
    }

    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        if !flag { show(target() ?? newWindow()) }
        return true
    }

    /// Folders opened from Finder, the Dock or `open -a Histq <folder>…` become tabs in the key window.
    func application(_ application: NSApplication, open urls: [URL]) {
        openFolders(urls)
    }

    // MARK: Windows

    /// The window menu commands act on: the key window, else the main one, else the newest.
    private func target() -> Entry? {
        entry(for: NSApp.keyWindow) ?? entry(for: NSApp.mainWindow) ?? entries.last
    }

    private func entry(for window: NSWindow?) -> Entry? {
        guard let window else { return nil }
        return entries.first { $0.window === window }
    }

    /// Creates a window with one Welcome tab, at `frame` when it is on a screen (session restore); it is not shown yet.
    private func newWindow(frame: NSRect? = nil) -> Entry {
        let model = WindowModel()
        let state = WindowState()
        let hosting = NSHostingController(
            rootView: MainView(navigation: model.navigation).environment(state).environment(model))
        // The window owns its size, not the SwiftUI content.
        hosting.sizingOptions = []
        // The window's toolbar is AppKit's (`HeaderToolbar`): SwiftUI bridges none, so content updates never touch it.
        hosting.sceneBridgingOptions = []
        let window = NSWindow(contentViewController: hosting)
        let toolbar = HeaderToolbar(model: model)
        window.toolbar = toolbar.toolbar
        window.title = "Histq"
        window.titleVisibility = .hidden
        // One row for the traffic lights and the toolbar; the tab strip is the content's first row under it.
        window.toolbarStyle = .unified
        // One background for the toolbar and the content, without a line between them.
        window.titlebarAppearsTransparent = true
        // A transparent title bar ignores double-clicks; AppKit's private flag gives them back, with every value of
        // System Settings › Desktop & Dock › "Double-click a window's title bar to". Developer ID app, not the App
        // Store; set only where AppKit has it.
        if window.responds(to: NSSelectorFromString("setTitlebarHandlesDoubleClickWhenTransparent:")) {
            window.setValue(true, forKey: "titlebarHandlesDoubleClickWhenTransparent")
        }
        window.titlebarSeparatorStyle = .none
        // Full size content: the background runs under the toolbar too.
        window.styleMask = [.titled, .closable, .miniaturizable, .resizable, .fullSizeContentView]
        window.isReleasedWhenClosed = false
        let previewScreen = WindowSizing.previewScreen
        window.setContentSize(WindowSizing.launchSize ?? WindowSizing.initialSize(on: previewScreen ?? NSScreen.main))
        WindowSizing.clampMinimum(of: window)
        if let frame, NSScreen.screens.contains(where: { $0.visibleFrame.intersects(frame) }) {
            // A restored frame (a QA run's comes from its own state dir); one on a screen that is gone is not used.
            window.setFrame(frame, display: false)
        } else if let previewScreen {
            // A background QA run: centered on the preview screen, away from the user's work.
            let visible = previewScreen.visibleFrame
            window.setFrameOrigin(NSPoint(x: visible.midX - window.frame.width / 2,
                                          y: visible.midY - window.frame.height / 2))
        } else if AppState.isStateDirMode {
            // QA runs never read or write the user's saved frame: AppKit keeps it in the standard defaults.
            window.center()
        } else if let anchor = target()?.window {
            // A further window: same size, a step down and right from the current one.
            window.setFrame(anchor.frame, display: false)
            window.setFrameTopLeftPoint(NSPoint(x: anchor.frame.minX + 24, y: anchor.frame.maxY - 24))
        } else {
            if !window.setFrameUsingName("MainWindow") { window.center() }
            window.setFrameAutosaveName("MainWindow")
        }
        // A saved or copied frame may be smaller than today's minimum.
        WindowSizing.clampMinimum(of: window)
        window.delegate = self
        DocumentWindow.configure(window, model: model) { [weak self] window in self?.openNativeTab(of: window) }
        model.closeWindow = { [weak window] in window?.performClose(nil) }
        let entry = Entry(window: window, model: model, state: state, toolbar: toolbar)
        entry.tabGroupObservation = window.observe(\.tabGroup) { _, _ in
            Task { @MainActor in SessionStore.schedule() }
        }
        entries.append(entry)
        trackSession(of: model)
        return entry
    }

    /// Saves the session when a window's tabs, its selected tab, or a tab's commit or profile change. Re-armed after
    /// each change, as long as the window is open.
    private func trackSession(of model: WindowModel) {
        withObservationTracking {
            _ = model.savedTabs
            _ = model.selectedIndex
        } onChange: { [weak self, weak model] in
            // Called before the change lands, off any isolation: re-arm on the main actor once it has.
            Task { @MainActor in
                guard let self, let model, self.entries.contains(where: { $0.model === model }) else { return }
                SessionStore.schedule()
                self.trackSession(of: model)
            }
        }
    }

    // MARK: Session

    /// Reopens the last session's windows: each native tab group in its tab order, with its selected tab, frames and
    /// app tabs; the front group ends up key. No saved session (or none readable) shows one Welcome window.
    private func restoreLastSession() async {
        let loaded = await SessionStore.loaded()
        // A folder opened while the session was read (Finder, the Dock) is what this launch shows.
        guard entries.isEmpty else { return }
        guard let loaded else { return show(newWindow()) }
        // Back to front, so the front group is ordered in last.
        for group in loaded.session.groups.reversed() {
            let windows = group.map { saved in
                let entry = newWindow(frame: saved.frame)
                entry.model.restore(saved.tabs, selected: saved.selectedTab, missing: loaded.missing)
                return entry
            }
            // The group's selected tab goes on screen first (no other tab flashes); the others join it in their saved
            // order, each next to its neighbour (`.above` = after it, `.below` = before it).
            let selected = group.firstIndex(where: \.isSelectedInGroup) ?? 0
            present(windows[selected].window, key: false)
            for index in windows.indices.dropFirst(selected + 1) {
                windows[index - 1].window.addTabbedWindow(windows[index].window, ordered: .above)
            }
            for index in windows.indices.prefix(selected).reversed() {
                windows[index + 1].window.addTabbedWindow(windows[index].window, ordered: .below)
            }
            present(windows[selected].window)
        }
        if !AppState.isBackgroundLaunch { NSApp.activate() }
    }

    /// The open windows as the session saves them: grouped by native tab group, groups front to back (the front
    /// window's group first), each in its tab bar order.
    private func currentSession() -> SavedSession {
        var depth: [ObjectIdentifier: Int] = [:]
        for (index, window) in NSApp.orderedWindows.enumerated() { depth[ObjectIdentifier(window)] = index }
        let groups = Dictionary(grouping: entries) { entry in
            entry.window.tabGroup.map(ObjectIdentifier.init) ?? ObjectIdentifier(entry.window)
        }
        let ordered = groups.values.sorted { lhs, rhs in
            let left = lhs.compactMap { depth[ObjectIdentifier($0.window)] }.min() ?? Int.max
            let right = rhs.compactMap { depth[ObjectIdentifier($0.window)] }.min() ?? Int.max
            return left < right
        }
        var windows: [SavedWindow] = []
        for (group, members) in ordered.enumerated() {
            for entry in members {
                let window = entry.window
                let tabGroup = window.tabGroup
                windows.append(SavedWindow(
                    x: window.frame.minX, y: window.frame.minY, width: window.frame.width, height: window.frame.height,
                    group: group,
                    tabIndex: tabGroup?.windows.firstIndex(of: window) ?? 0,
                    isSelectedInGroup: tabGroup.map { $0.selectedWindow === window } ?? true,
                    tabs: entry.model.savedTabs,
                    selectedTab: entry.model.selectedIndex))
            }
        }
        return SavedSession(windows: windows)
    }

    private func show(_ entry: Entry) {
        present(entry.window)
        if !AppState.isBackgroundLaunch { NSApp.activate() }
    }

    /// Puts `window` on screen, in front and key (or only in front). A DEBUG `-HistqBackground YES` launch (QA shots,
    /// the preview) orders it behind every other window instead and never makes it key: it must not take the user's
    /// focus or cover their work. `screencapture -l` still captures it. Once the user works in it (the app is active,
    /// e.g. ⌘, or ⇧⌘N pressed in it), windows come to the front as usual.
    private func present(_ window: NSWindow, key: Bool = true) {
        if AppState.isBackgroundLaunch && !NSApp.isActive {
            window.orderBack(nil)
        } else if key {
            window.makeKeyAndOrderFront(nil)
        } else {
            window.orderFront(nil)
        }
    }

    /// The native tab bar's "+": a new window with a Welcome tab, as the next native tab of `window`'s group.
    private func openNativeTab(of window: NSWindow) {
        let entry = newWindow()
        window.addTabbedWindow(entry.window, ordered: .above)
        show(entry)
    }

    /// Opens each folder as a tab in the key window (a new window if there is none); files are ignored.
    private func openFolders(_ urls: [URL]) {
        let folders = urls.filter { url in
            url.isFileURL && (try? url.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) == true
        }
        guard !folders.isEmpty else { return }
        #if DEBUG
        if entries.isEmpty, let count = AppState.launchFlag("-HistqTabbedWindows").flatMap(Int.init), count > 1 {
            return openTabbedWindows(folders, count: count)
        }
        #endif
        let entry = target() ?? newWindow()
        for folder in folders { entry.model.openTab(folder) }
        show(entry)
    }

    #if DEBUG
    /// DEBUG `-HistqTabbedWindows N` (QA of native tabs): the launch's folders spread over N windows (folder i in
    /// window i mod N; a window without one keeps its Welcome tab), merged into one native tab group whose first tab
    /// shows. The first window is on screen before the others join it, and is selected again at the end, so the
    /// window `scripts/shot.sh` finds first is the one it captures.
    private func openTabbedWindows(_ folders: [URL], count: Int) {
        let group = (0..<count).map { _ in newWindow() }
        for (index, folder) in folders.enumerated() { group[index % count].model.openTab(folder) }
        show(group[0])
        for (previous, entry) in zip(group, group.dropFirst()) {
            previous.window.addTabbedWindow(entry.window, ordered: .above)
        }
        show(group[0])
    }
    #endif

    func windowWillClose(_ notification: Notification) {
        guard let window = notification.object as? NSWindow else { return }
        let model = entries.first { $0.window === window }?.model
        // An open palette holds row closures over the window's sessions; drop it so they are freed with the window.
        model?.closePalette()
        // The closed window's views can keep its sessions (and their AI runs) alive a while: a running AI job stops
        // now, before it sends the diff.
        model?.sessions.values.forEach { $0.closeAI() }
        // Closing a window never calls the sessions' `close()`: their shells end here.
        model?.sessions.values.forEach { $0.endTerminal() }
        entries.removeAll { $0.window === window }
        SessionStore.schedule()
    }

    /// Frames, the front window and the selected native tab are part of the session.
    func windowDidMove(_ notification: Notification) {
        SessionStore.schedule()
    }

    func windowDidResize(_ notification: Notification) {
        SessionStore.schedule()
    }

    #if DEBUG
    func windowShouldZoom(_ window: NSWindow, toFrame newFrame: NSRect) -> Bool {
        DoubleClickProbe.zoom(window, to: newFrame)
        return true
    }
    #endif

    func windowDidBecomeMain(_ notification: Notification) {
        SessionStore.schedule()
    }

    /// The minimum size follows the screen the window is on.
    func windowDidChangeScreen(_ notification: Notification) {
        guard let window = notification.object as? NSWindow, entry(for: window) != nil else { return }
        WindowSizing.clampMinimum(of: window)
    }

    /// A display was added, removed or resized: each window's minimum follows its screen again.
    func applicationDidChangeScreenParameters(_ notification: Notification) {
        for entry in entries { WindowSizing.clampMinimum(of: entry.window) }
    }

    func windowDidChangeOcclusionState(_ notification: Notification) {
        guard let window = notification.object as? NSWindow, let entry = entry(for: window) else { return }
        entry.state.isVisible = window.occlusionState.contains(.visible)
    }

    // MARK: Menu actions

    @objc func newWindowAction(_ sender: Any?) {
        show(newWindow())
    }

    @objc func newTab(_ sender: Any?) {
        guard let entry = target() else { return show(newWindow()) }
        entry.model.openTab(nil)
        show(entry)
    }

    @objc func openDocument(_ sender: Any?) {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.allowsMultipleSelection = true
        panel.prompt = "Open"
        panel.message = "Choose one or more repositories"
        Task { @MainActor in
            guard await panel.begin() == .OK else { return }
            self.openFolders(panel.urls)
        }
    }

    /// Opens a Welcome tab, where the clone form lives.
    @objc func cloneRepository(_ sender: Any?) {
        newTab(sender)
    }

    /// Closes the key window's selected tab, and the window with its last tab.
    @objc func closeTab(_ sender: Any?) {
        guard let entry = entry(for: NSApp.keyWindow) else {
            NSApp.keyWindow?.performClose(sender)
            return
        }
        // Settings hides the tab: ⌘W closes Settings or leaves the page first, never closing a tab out of
        // sight.
        if entry.model.isSettingsOpen {
            entry.model.closeSettings()
            return
        }
        if entry.model.navigation.page != .home {
            entry.model.navigation.page = .home
            return
        }
        if !entry.model.closeSelectedTab() { entry.window.performClose(sender) }
    }

    /// ⇧⌘T: reopens the key window's last closed tab; again for the one closed before it.
    @objc func reopenClosedTab(_ sender: Any?) {
        guard let entry = entry(for: NSApp.keyWindow) else { return }
        entry.model.reopenClosedTab()
    }

    /// ⌘K: opens the key window's command palette, or closes it. A main menu item, so it works wherever the focus is
    /// (the AppKit toolbar, a table, the palette's own field).
    @objc func toggleCommandPalette(_ sender: Any?) {
        guard let entry = target() else { return }
        entry.model.togglePalette()
    }

    /// Opens the Settings modal in the key window (⌘,); it stays open when it already shows.
    @objc func showSettings() {
        let entry = target() ?? newWindow()
        entry.model.openSettings()
        show(entry)
    }

    /// The standard About panel: the app icon, name, version and copyright from the Info.plist, then the credits.
    @objc func showAbout() {
        NSApp.orderFrontStandardAboutPanel(options: [.credits: Self.aboutCredits])
    }

    /// The description, the license and the website link, centered under the version.
    private static var aboutCredits: NSAttributedString {
        let paragraph = NSMutableParagraphStyle()
        paragraph.alignment = .center
        let attributes: [NSAttributedString.Key: Any] = [
            .font: NSFont.systemFont(ofSize: NSFont.smallSystemFontSize), .paragraphStyle: paragraph,
            .foregroundColor: NSColor.secondaryLabelColor,
        ]
        let credits = NSMutableAttributedString(
            string: "A native macOS git client that drives the git you already have.\n\nLicensed under GPL-3.0\n",
            attributes: attributes)
        var link = attributes
        link[.link] = URL(string: "https://histq.coprimal.dev")!
        credits.append(NSAttributedString(string: "histq.coprimal.dev", attributes: link))
        return credits
    }

    /// ⌃`: shows or hides the selected repo tab's terminal drawer. A main menu item, so it works with the focus in the
    /// terminal too.
    @objc func toggleTerminal(_ sender: Any?) {
        target()?.model.toggleTerminal()
    }

    /// View › Move Tabs to the Left/Top: writes General › Tab position, as the palette command does; the windows
    /// follow it live.
    @objc func toggleTabPosition(_ sender: Any?) {
        let next: TabPosition = TabPosition.current == .left ? .top : .left
        Preferences.defaults.set(next.rawValue, forKey: PrefKey.tabPosition.rawValue)
    }

    /// View › Classic / Stacked / Focus (the item's `representedObject`): Focus again (⌥⌘F) leaves Focus. The windows
    /// follow it live.
    @objc func chooseLayout(_ sender: NSMenuItem) {
        guard let preset = (sender.representedObject as? String).flatMap(LayoutPreset.init(rawValue:)) else { return }
        LayoutPreset.choose(preset)
    }

    /// View › Reset Layout: default panel widths and Stacked split, and Classic.
    @objc func resetLayout(_ sender: Any?) {
        LayoutPreset.reset()
    }

    @objc func checkForUpdates(_ sender: Any?) {
        updater.checkForUpdates()
    }

    // MARK: Find

    /// `performFindPanelAction(_:)` with `showFindPanel`, as the focused view gets it: the Find item's stand-in when it
    /// asks the responder chain.
    private let findPanelItem: NSMenuItem = {
        let item = NSMenuItem(title: "Find…", action: #selector(NSTextView.performFindPanelAction(_:)), keyEquivalent: "")
        item.tag = Int(NSFindPanelAction.showFindPanel.rawValue)
        return item
    }()

    /// Edit › Find… (⌘F). A focused view with its own find bar (the terminal, the conflict editor's output) shows it;
    /// anywhere else in a repo tab the graph search opens, or takes the focus again. Not nil-targeted: a text field or
    /// a text view without a find bar answers `performFindPanelAction(_:)` with a disabled item, which would end the
    /// responder chain there, so this asks the chain itself and only hands the action to a view that takes it.
    @objc func findCommits(_ sender: Any?) {
        // Off under a modal, Settings or the palette, also for a find bar behind it.
        guard target()?.model.isShowingModal != true else { return }
        if let responder = findPanelResponder() {
            NSApp.sendAction(#selector(NSTextView.performFindPanelAction(_:)), to: responder, from: findPanelItem)
            return
        }
        guard let session = searchableSession() else { return }
        session.graphSearch.open()
    }

    /// The first responder of the key window's chain that answers `performFindPanelAction(_:)` with `showFindPanel`
    /// enabled; nil when none does.
    private func findPanelResponder() -> AnyObject? {
        guard let responder = NSApp.target(
            forAction: #selector(NSTextView.performFindPanelAction(_:)), to: nil, from: findPanelItem) as AnyObject?,
            responder !== self
        else { return nil }
        if let validator = responder as? NSMenuItemValidation {
            return validator.validateMenuItem(findPanelItem) ? responder : nil
        }
        if let validator = responder as? NSUserInterfaceValidations {
            return validator.validateUserInterfaceItem(findPanelItem) ? responder : nil
        }
        return responder
    }

    /// The selected repo tab whose graph shows, when nothing covers it: no modal, Settings or palette, no open file,
    /// pull request or issue over the graph.
    private func searchableSession() -> RepoSession? {
        guard let model = target()?.model, !model.isShowingModal, let session = model.actionSession,
              session.openFile == nil, session.openHosted == nil
        else { return nil }
        return session
    }

    func validateMenuItem(_ menuItem: NSMenuItem) -> Bool {
        if menuItem.action == #selector(closeTab(_:)) { return NSApp.keyWindow != nil }
        if menuItem.action == #selector(reopenClosedTab(_:)) {
            return entry(for: NSApp.keyWindow)?.model.canReopenClosedTab ?? false
        }
        if menuItem.action == #selector(checkForUpdates(_:)) {
            // Disabled while the updater is off (no update signing key in this build yet).
            menuItem.toolTip = updater.canCheckForUpdates ? nil : "Updates are off: this build has no update signing key."
            return updater.canCheckForUpdates
        }
        if menuItem.action == #selector(findCommits(_:)) {
            guard target()?.model.isShowingModal != true else { return false }
            return findPanelResponder() != nil || searchableSession() != nil
        }
        if menuItem.action == #selector(toggleTerminal(_:)) {
            let session = target()?.model.actionSession
            // A pending drawer (opened with a new tab, no shell yet): the item starts the shell, it does not hide.
            let hides = session?.isTerminalOpen == true && session?.isTerminalPending == false
            menuItem.title = hides ? "Hide Terminal" : "Show Terminal"
            return session != nil
        }
        if menuItem.action == #selector(toggleTabPosition(_:)) {
            menuItem.title = TabPosition.current == .left ? "Move Tabs to the Top" : "Move Tabs to the Left"
        }
        if menuItem.action == #selector(chooseLayout(_:)) {
            menuItem.state = menuItem.representedObject as? String == LayoutPreset.current.rawValue ? .on : .off
        }
        return true
    }

    /// App menu (About, Check for Updates, Settings, Hide, Quit), File, Edit, View (the terminal, the tab position, the layout presets) and Window menus:
    /// without Edit, text fields lose copy and paste.
    private func makeMainMenu() -> NSMenu {
        let appMenu = NSMenu()
        appMenu.addItem(withTitle: "About Histq", action: #selector(showAbout), keyEquivalent: "").target = self
        appMenu.addItem(withTitle: "Check for Updates…", action: #selector(checkForUpdates(_:)), keyEquivalent: "")
            .target = self
        appMenu.addItem(.separator())
        appMenu.addItem(withTitle: "Settings…", action: #selector(showSettings), keyEquivalent: ",").target = self
        appMenu.addItem(.separator())
        appMenu.addItem(withTitle: "Hide Histq", action: #selector(NSApplication.hide(_:)), keyEquivalent: "h")
        appMenu.addItem(withTitle: "Hide Others", action: #selector(NSApplication.hideOtherApplications(_:)),
                        keyEquivalent: "h").keyEquivalentModifierMask = [.command, .option]
        appMenu.addItem(.separator())
        appMenu.addItem(withTitle: "Quit Histq", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q")
        let fileMenu = NSMenu(title: "File")
        fileMenu.addItem(withTitle: "New Window", action: #selector(newWindowAction(_:)), keyEquivalent: "N").target = self
        fileMenu.addItem(withTitle: "New Tab", action: #selector(newTab(_:)), keyEquivalent: "t").target = self
        // ⌘N opens a new tab too: hidden, so the menu shows only ⌘T.
        let newTabItem = fileMenu.addItem(withTitle: "New Tab", action: #selector(newTab(_:)), keyEquivalent: "n")
        newTabItem.target = self
        newTabItem.isHidden = true
        newTabItem.allowsKeyEquivalentWhenHidden = true
        fileMenu.addItem(withTitle: "Open…", action: #selector(openDocument(_:)), keyEquivalent: "o").target = self
        fileMenu.addItem(withTitle: "Clone…", action: #selector(cloneRepository(_:)), keyEquivalent: "").target = self
        fileMenu.addItem(withTitle: "Command Palette…", action: #selector(toggleCommandPalette(_:)), keyEquivalent: "k")
            .target = self
        // ⌘P opens the palette too: hidden, so the menu shows only ⌘K.
        let paletteItem = fileMenu.addItem(withTitle: "Command Palette…", action: #selector(toggleCommandPalette(_:)),
                                           keyEquivalent: "p")
        paletteItem.target = self
        paletteItem.isHidden = true
        paletteItem.allowsKeyEquivalentWhenHidden = true
        fileMenu.addItem(.separator())
        fileMenu.addItem(withTitle: "Close Tab", action: #selector(closeTab(_:)), keyEquivalent: "w").target = self
        fileMenu.addItem(withTitle: "Reopen Closed Tab", action: #selector(reopenClosedTab(_:)), keyEquivalent: "T")
            .target = self
        fileMenu.addItem(withTitle: "Close Window", action: #selector(NSWindow.performClose(_:)), keyEquivalent: "W")
        let editMenu = NSMenu(title: "Edit")
        // Nil-targeted: the responder chain (text views, the window's undo manager, the graph) answers `undo:`/`redo:`.
        // AppKit declares no Swift method for them, so the graph table's own `undo(_:)`/`redo(_:)` name the selectors.
        editMenu.addItem(withTitle: "Undo", action: #selector(GraphTableView.undo(_:)), keyEquivalent: "z")
        editMenu.addItem(withTitle: "Redo", action: #selector(GraphTableView.redo(_:)), keyEquivalent: "Z")
        editMenu.addItem(.separator())
        editMenu.addItem(withTitle: "Cut", action: #selector(NSText.cut(_:)), keyEquivalent: "x")
        editMenu.addItem(withTitle: "Copy", action: #selector(NSText.copy(_:)), keyEquivalent: "c")
        editMenu.addItem(withTitle: "Paste", action: #selector(NSText.paste(_:)), keyEquivalent: "v")
        editMenu.addItem(withTitle: "Select All", action: #selector(NSText.selectAll(_:)), keyEquivalent: "a")
        editMenu.addItem(.separator())
        // Targeted, not nil: `findCommits` hands ⌘F to a focused view with a find bar itself (see there).
        let findItem = editMenu.addItem(withTitle: "Find…", action: #selector(findCommits(_:)), keyEquivalent: "f")
        findItem.tag = Int(NSFindPanelAction.showFindPanel.rawValue)
        findItem.target = self
        let viewMenu = NSMenu(title: "View")
        let terminalItem = viewMenu.addItem(withTitle: "Show Terminal", action: #selector(toggleTerminal(_:)),
                                            keyEquivalent: "`")
        terminalItem.keyEquivalentModifierMask = [.control]
        terminalItem.target = self
        viewMenu.addItem(withTitle: "Move Tabs to the Left", action: #selector(toggleTabPosition(_:)), keyEquivalent: "")
            .target = self
        viewMenu.addItem(.separator())
        // ⌥⌘F: ⌃⌘F is AppKit's Enter Full Screen.
        for preset in [LayoutPreset.classic, .stacked, .focus] {
            let item = viewMenu.addItem(withTitle: preset.rawValue.capitalized, action: #selector(chooseLayout(_:)),
                                        keyEquivalent: preset == .focus ? "f" : "")
            item.keyEquivalentModifierMask = [.command, .option]
            item.representedObject = preset.rawValue
            item.target = self
        }
        viewMenu.addItem(withTitle: "Reset Layout", action: #selector(resetLayout(_:)), keyEquivalent: "").target = self
        let windowMenu = NSMenu(title: "Window")
        windowMenu.addItem(withTitle: "Minimize", action: #selector(NSWindow.performMiniaturize(_:)), keyEquivalent: "m")
        windowMenu.addItem(withTitle: "Zoom", action: #selector(NSWindow.performZoom(_:)), keyEquivalent: "")
        NSApp.windowsMenu = windowMenu
        let mainMenu = NSMenu()
        for submenu in [appMenu, fileMenu, editMenu, viewMenu, windowMenu] {
            let item = NSMenuItem()
            item.submenu = submenu
            mainMenu.addItem(item)
        }
        return mainMenu
    }
}

/// A window's size limits. Its minimum fits the repo layout's three panels at their minimums, and the vertical tabs
/// in that position, for the layout preset (`RepoLayoutMetrics.minimumWindowSize(tabPosition:preset:)`), but never
/// exceeds the visible frame of the screen it is on. With a full-size content view the frame and the content have the
/// same size.
@MainActor
private enum WindowSizing {
    /// A new window's size when the screen has room for it.
    static let preferred = NSSize(width: 1200, height: 760)

    /// A background QA run's screen (DEBUG `-HistqBackground YES` with a state dir): the display named "ARZOPA" when
    /// connected, so its windows open away from the user's work; nil otherwise (the usual placement).
    static var previewScreen: NSScreen? {
        guard AppState.isBackgroundLaunch, AppState.isStateDirMode else { return nil }
        return NSScreen.screens.first { $0.localizedName.localizedCaseInsensitiveContains("ARZOPA") }
    }

    /// DEBUG `-HistqWindowSize <width>x<height>` (e.g. `912x520`, the minimum): a new window's size, for QA of the
    /// layout at a given size; the minimum still applies (`clampMinimum`). nil without the flag, and in Release.
    static let launchSize: NSSize? = AppState.launchFlag("-HistqWindowSize").flatMap { value in
        let parts = value.split(separator: "x").compactMap { Double($0) }
        return parts.count == 2 ? NSSize(width: parts[0], height: parts[1]) : nil
    }

    /// `preferred`, at least the minimum, at most the screen's visible frame.
    static func initialSize(on screen: NSScreen?) -> NSSize {
        let minimum = RepoLayoutMetrics.minimumWindowSize(tabPosition: .current, preset: .current)
        let size = NSSize(width: max(preferred.width, minimum.width), height: max(preferred.height, minimum.height))
        guard let visible = screen?.visibleFrame.size else { return size }
        return NSSize(width: min(size.width, visible.width), height: min(size.height, visible.height))
    }

    /// Sets the window's minimum size for its screen, and grows the window (top edge kept, inside the screen) when
    /// it is smaller than that.
    static func clampMinimum(of window: NSWindow) {
        let minimum = RepoLayoutMetrics.minimumWindowSize(tabPosition: .current, preset: .current)
        guard let visible = (window.screen ?? NSScreen.main)?.visibleFrame else {
            window.minSize = minimum
            return
        }
        let clamped = NSSize(width: min(minimum.width, visible.width), height: min(minimum.height, visible.height))
        window.minSize = clamped
        var frame = window.frame
        guard frame.width < clamped.width || frame.height < clamped.height else { return }
        let top = frame.maxY
        frame.size = NSSize(width: max(frame.width, clamped.width), height: max(frame.height, clamped.height))
        frame.origin.y = top - frame.height
        frame.origin.x = min(max(frame.minX, visible.minX), visible.maxX - frame.width)
        frame.origin.y = min(max(frame.minY, visible.minY), visible.maxY - frame.height)
        window.setFrame(frame, display: window.isVisible)
    }
}
