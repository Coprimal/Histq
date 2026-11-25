// The app entry: an AppKit delegate that owns the windows, their tabs, the main menu and the open handling.
import AppKit
import HistqCore
import os
import SwiftUI
import UniformTypeIdentifiers

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

/// What `AppDelegate.moveTab` did: the tab moved, or why it stayed (shown by the menu, the palette and the drag).
enum MoveResult: Equatable {
    case moved
    case refused(String)
}

/// Owns the windows, one `WindowModel` each, and the main menu for the app lifetime.
@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate, NSWindowDelegate, NSMenuItemValidation, NSMenuDelegate {
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
    /// The layouts of the workspaces not open now, at most one per identity key, each with its own `open`: read at
    /// launch, written back as they were so a capture never drops them. Opening a workspace takes its entry out.
    private var workspaceLayouts: [WorkspaceLayout] = []
    /// The open workspaces; their windows point to them (`WindowModel.workspace`).
    private(set) var workspaces: [Workspace] = []
    /// The identity keys of the workspace files being read (`openWorkspace`): a second open of one is a no-op, and
    /// Save As / New Workspace refuse them.
    private var openingKeys = Set<String>()
    /// The files of the workspaces a settled close burst dropped, by identity key, for the next write pass.
    private var settledFiles: [String: (file: WorkspaceFile, isReadOnly: Bool)] = [:]
    /// Workspace files opened while the launch restores the last session, opened after it; nil once it has.
    private var launchWorkspaces: [URL]? = []
    /// Folders or workspace files arrived while the launch restored the last session (`open -a Histq <path>`, Finder):
    /// the first-run gate never shows the onboarding for such a launch.
    private var launchedWithPaths = false
    /// Quit has begun: closing windows keep no close-burst snapshot.
    private var isTerminating = false
    private static let logger = Logger(subsystem: "com.math2it.histq", category: "session")
    /// The tab position and layout preset the windows' minimum sizes were last set for.
    private var tabPosition = TabPosition.current
    private var layoutPreset = LayoutPreset.current
    /// Sparkle; stays off (menu item disabled) while `SUPublicEDKey` is empty. Each window's toolbar shows its Update
    /// button.
    private let updater = Updater()
    /// File › Recent Workspaces, filled when it opens (`menuNeedsUpdate`).
    private let recentWorkspacesMenu = NSMenu(title: "Recent Workspaces")

    func applicationWillFinishLaunching(_ notification: Notification) {
        // Histq is dark mode only, whatever the system's appearance.
        NSApp.appearance = NSAppearance(named: .darkAqua)
        NSApp.mainMenu = makeMainMenu()
        // General › Tab position moves the tabs into panel 0, and Columns adds a 4th column, which the minimum width
        // counts. Posted for every key, possibly off the main thread; only a change of the position or preset
        // re-clamps.
        NotificationCenter.default.addObserver(
            forName: UserDefaults.didChangeNotification, object: Preferences.defaults, queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated { self?.preferencesChanged() }
        }
    }

    private func preferencesChanged() {
        let position = TabPosition.current, preset = LayoutPreset.current
        guard position != tabPosition || preset != layoutPreset else { return }
        tabPosition = position
        layoutPreset = preset
        for entry in entries { WindowSizing.clampMinimum(of: entry.window) }
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        // Tooltips (`.help`) after 0.25 s instead of the system's 1.5 s, as in EchoDiar.
        UserDefaults.standard.register(defaults: ["NSInitialToolTipDelay": 250])
        updater.hasUpdateButton = { [unowned self] in
            entries.contains { $0.window.isVisible && $0.toolbar.hasUpdateItem }
        }
        updater.start()
        // Folders given at launch (`open -a Histq <repo>`) arrive in `application(_:open:)` first and already made
        // the window: they are what this launch shows. Without any, the last session comes back once read. Either way
        // capture starts only once the saved session is read, so its workspace layouts are kept.
        Task { @MainActor in
            await self.restoreLastSession()
            // Demo repositories an earlier run left behind (a quit or crash during the tour), removed off the main
            // actor; the onboarding starts only once they are gone, so its tour never races the cleanup.
            let cleanup = Task.detached(priority: .utility) {
                Self.removeLeftoverDemos(in: StatePaths.onboardingDemoParent)
            }
            self.finishLaunching()
            await cleanup.value
            await self.startLaunchOnboarding()
        }
    }

    /// Removes every `demo-*` folder in `parent` that `DemoRepository.remove` accepts (marked, directly inside
    /// `parent`); a missing `parent` is nothing to clean.
    private nonisolated static func removeLeftoverDemos(in parent: URL) {
        let names = (try? FileManager.default.contentsOfDirectory(atPath: parent.path(percentEncoded: false))) ?? []
        for name in names where name.hasPrefix("demo-") {
            let base = parent.appending(path: name, directoryHint: .isDirectory)
            do {
                try DemoRepository.remove(base: base, parent: parent)
            } catch {
                Logger(subsystem: "com.math2it.histq", category: "onboarding")
                    .error("Leftover demo not removed: \(String(describing: error), privacy: .public)")
            }
        }
    }

    /// The launch's onboarding. Without a DEBUG `-HistqOnboarding` flag (always in Release) the first-run gate decides:
    /// it shows on a truly empty state, marks an existing user done silently, and stays off for a state-dir or a
    /// launch with paths. The flag: a step or the tour opens there, `auto` runs the gate as if no state dir were set,
    /// `off` or an unknown step do nothing. It starts on the target window, and never when a window runs one already.
    private func startLaunchOnboarding() async {
        let step: OnboardingModel.Step
        var stop: String?
        switch AppState.launchOnboarding {
        case .off:
            return
        case .step(let id):
            guard let named = OnboardingModel.Step(launch: id) else { return }
            // The clone step shows only with a connected GitHub account, read from the profiles.
            if named == .clone { _ = await ProfileLibrary.shared.loaded() }
            step = named
        case .tour(let id):
            // At the stop `id` names (or the next one the window has); an unknown id, at the first one.
            step = .tour
            stop = id
        case nil, .auto:
            let decision = OnboardingGate.decide(
                done: Preferences.defaults.bool(forKey: PrefKey.onboardingDone.rawValue),
                recentRepos: RecentRepos.shared.urls.count, recentWorkspaces: RecentRepos.workspaces.urls.count,
                session: await SessionStore.loaded()?.session,
                stateDirMode: AppState.launchOnboarding == nil && AppState.isStateDirMode,
                launchedWithPaths: launchedWithPaths, forced: false)
            switch decision {
            case .show: step = .welcome
            case .markDone: return Preferences.defaults.set(true, forKey: PrefKey.onboardingDone.rawValue)
            case .stay: return
            }
        }
        guard !entries.contains(where: { $0.model.isOnboarding }), let entry = target() else { return }
        entry.model.startOnboarding(at: step, stop: stop)
    }

    /// The launch's windows are open: capture starts (saving them now, so a launch with folders is restorable too),
    /// then the DEBUG `-HistqSelect` request.
    private func finishLaunching() {
        SessionStore.onWriteResult = { [unowned self] key, error in
            guard let workspace = workspaces.first(where: { $0.key == key }) else { return }
            workspace.writeFailed = error != nil
            workspace.writeError = error?.localizedDescription
        }
        SessionStore.start { [unowned self] in
            // First: a workspace whose windows all closed by hand is written as it was before (`settleCloseBursts`).
            settleCloseBursts()
            var files = currentWorkspaceFiles()
            for (key, settled) in settledFiles where files[key] == nil { files[key] = settled }
            settledFiles = [:]
            return SessionStore.Snapshot(session: currentSession(), workspaces: files)
        }
        SessionStore.schedule()
        // Workspace files given at launch (Finder, `open -a Histq <file>`), after the last session.
        let queued = launchWorkspaces ?? []
        launchWorkspaces = nil
        for url in queued { openWorkspace(url) }
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
        if let path = AppState.launchSaveWorkspace {
            // Once the restored tabs have settled (their repo keys are read off the main thread).
            Task { @MainActor in
                try? await Task.sleep(for: .milliseconds(500))
                guard let entry = self.target() else { return }
                self.saveWorkspace(to: URL(filePath: (path as NSString).expandingTildeInPath), from: entry)
            }
        }
        if let name = AppState.launchCloseWorkspace {
            Task { @MainActor in
                guard let workspace = self.workspaces.first(where: { $0.name == name }) else { return }
                self.close(workspace)
            }
        }
        if let spec = AppState.launchFlag("-HistqMoveTab") {
            Task { @MainActor in await self.debugMoveTab(spec) }
        }
        // `-HistqTabWalk <rounds>[,<ms>]`: at window level, once per launch (a session's flag would run in every tab).
        if let spec = AppState.launchFlag("-HistqTabWalk") {
            Task { @MainActor in await self.target()?.model.runTabWalk(spec) }
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
            // The worktree list too: worktree rows (merge in another worktree) read it.
            if !isRepoTab || (session?.refs.value != nil && session?.status.value != nil && session?.log.value != nil
                && session?.worktrees.value != nil) {
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
            session.run(confirmation.write, title: confirmation.operation, key: confirmation.key,
                        then: confirmation.afterSuccess)
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

    /// Quit saves the session while the windows are still open; the windows closing after it save nothing. A close
    /// burst still pending settles first. A tab with unsaved edits cancels it first: its leave prompt shows, and its
    /// Save or Don't Save quits again.
    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        if revealUnsavedTab(in: entries, retry: { NSApp.terminate(nil) }) { return .terminateCancel }
        isTerminating = true
        settleCloseBursts()
        SessionStore.saveForQuit()
        return .terminateNow
    }

    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        if !flag { show(target() ?? newWindow()) }
        return true
    }

    /// Workspace files open as workspaces (at launch, once the last session is restored); folders opened from
    /// Finder, the Dock or `open -a Histq <folder>…` become tabs in the key window.
    func application(_ application: NSApplication, open urls: [URL]) {
        let files = urls.filter { $0.isFileURL && $0.pathExtension.lowercased() == Self.workspaceExtension }
        if launchWorkspaces != nil {
            if !urls.isEmpty { launchedWithPaths = true }
            launchWorkspaces?.append(contentsOf: files)
        } else {
            for file in files { openWorkspace(file) }
        }
        openFolders(urls.filter { !files.contains($0) })
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

    /// Creates a window with one Welcome tab, at `frame` when it is on a screen (session restore), in `workspace` (nil:
    /// Untitled); it is not shown yet.
    private func newWindow(frame: NSRect? = nil, workspace: Workspace? = nil) -> Entry {
        let model = WindowModel()
        // Before any session is made, so each one's `profileScope` follows the membership.
        model.workspace = workspace
        let state = WindowState()
        let hosting = NSHostingController(
            rootView: MainView(navigation: model.navigation).environment(state).environment(model))
        // The window owns its size, not the SwiftUI content.
        hosting.sizingOptions = []
        // The window's toolbar is AppKit's (`HeaderToolbar`): SwiftUI bridges none, so content updates never touch it.
        hosting.sceneBridgingOptions = []
        let window = NSWindow(contentViewController: hosting)
        let toolbar = HeaderToolbar(model: model, updater: updater)
        window.toolbar = toolbar.toolbar
        toolbar.insertWorkspaceItemIfMissing()
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
        // A workspace keeps its file as it was before a close burst that may close all its windows.
        model.willEmpty = { [weak self, weak model] in
            guard let self, let workspace = model?.workspace else { return }
            keepPreCloseSnapshot(of: workspace)
        }
        // A group's menu › Move Group to New Window: its tabs open in a new window of the same workspace, as a session
        // restore does.
        model.openWindow = { [weak self, weak model] tabs, groups, selected, missing in
            guard let self else { return }
            let entry = newWindow(workspace: model?.workspace)
            entry.model.restore(tabs, selected: selected, missing: missing, groups: groups)
            show(entry)
        }
        model.window = window
        let entry = Entry(window: window, model: model, state: state, toolbar: toolbar)
        entry.tabGroupObservation = window.observe(\.tabGroup) { _, _ in
            Task { @MainActor in SessionStore.schedule() }
        }
        entries.append(entry)
        trackSession(of: model)
        return entry
    }

    /// Saves the session when a window's tabs, its selected tab, a tab's commit or profile, a manual group or its
    /// closed groups change. Re-armed after each change, as long as the window is open.
    private func trackSession(of model: WindowModel) {
        withObservationTracking {
            _ = model.savedTabs
            _ = model.selectedIndex
            _ = model.savedTabGroups
            _ = model.savedClosedGroups
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

    /// Reopens the last session's windows: the Untitled ones and those of every workspace that was open (each read off
    /// the main thread; one that cannot be read is logged and skipped, its layout kept `open` for the next launch),
    /// laid out by their native tab groups. No window at all shows one Welcome window. The saved workspace layouts are
    /// kept for capture in every case, a launch with folders included.
    private func restoreLastSession() async {
        let loaded = await SessionStore.loaded()
        workspaceLayouts = loaded?.session.workspaces ?? []
        // A folder opened while the session was read (Finder, the Dock) is what this launch shows.
        guard entries.isEmpty else { return }
        let reads = workspaceLayouts.filter(\.open).map { layout in
            (layout.path, Task { try await Workspace.open(URL(fileURLWithPath: layout.path, isDirectory: false)) })
        }
        var opened: [(path: String, read: (Workspace, WorkspaceFile.Resolved, repoKeys: [String: String]))] = []
        for (path, read) in reads {
            do {
                opened.append((path, try await read.value))
            } catch {
                let reason = error.localizedDescription
                Self.logger.error("workspace not reopened: \(path, privacy: .private): \(reason, privacy: .public)")
            }
        }
        // Same while the workspaces were read: their layouts stay `open` for the next launch.
        guard entries.isEmpty else { return }
        var placed = (loaded?.session.windows ?? []).map { saved in
            let entry = newWindow(frame: saved.frame)
            entry.model.restore(saved.tabs, selected: saved.selectedTab, missing: loaded?.missing ?? [],
                                groups: saved.manualTabGroups, closedGroups: saved.closedTabGroups)
            return Placed(entry: entry, group: saved.group, tabIndex: saved.tabIndex,
                          isSelectedInGroup: saved.isSelectedInGroup)
        }
        // Two layouts may name one file (a symlink changed since): it opens once.
        var restored: [Workspace] = []
        for (path, (workspace, resolved, repoKeys)) in opened
        where !workspaces.contains(where: { $0.key == workspace.key }) {
            placed += restoreWindows(of: workspace, resolved, repoKeys: repoKeys, layoutPath: path)
            restored.append(workspace)
        }
        // A workspace file given at launch opens next: it shows instead.
        guard !placed.isEmpty else {
            if launchWorkspaces?.isEmpty ?? true { show(newWindow()) }
            return
        }
        restoreGroups(placed)
        for workspace in restored { offerProfileImport(workspace) }
    }

    /// A restored window waiting to be laid out: its native tab group (nil: a group of its own), its place in the
    /// group's tab bar and whether its group shows it.
    private struct Placed {
        let entry: Entry
        let group: Int?
        let tabIndex: Int
        let isSelectedInGroup: Bool
    }

    /// Restores the windows of `workspace` as `resolved` (read off the main thread, `Workspace.open`) has them, with
    /// the frames, native groups, selection and collapsed manual groups of its layout (the entry at `layoutPath`, else
    /// at its key), which it takes out of `workspaceLayouts`; with none, each window gets the default frame and a group
    /// of its own, its first tab selected. The workspace then joins `workspaces` and seeds the writer with its file as
    /// captured now, so it is written only once it changes. The caller lays the windows out (`restoreGroups`).
    private func restoreWindows(of workspace: Workspace, _ resolved: WorkspaceFile.Resolved,
                                repoKeys: [String: String], layoutPath: String? = nil) -> [Placed] {
        let path = layoutPath ?? workspace.key
        let layout = workspaceLayouts.first { $0.path == path }
        workspaceLayouts.removeAll { $0.path == path || $0.path == workspace.key }
        var saved: [UUID: WorkspaceLayout.Window] = [:]
        for window in layout?.windows ?? [] where saved[window.id] == nil { saved[window.id] = window }
        let placed = resolved.windows.map { window in
            let place = saved[window.id]
            let entry = newWindow(frame: place.map { NSRect(x: $0.x, y: $0.y, width: $0.width, height: $0.height) },
                                  workspace: workspace)
            entry.model.windowID = window.id
            let collapsed = Set(place?.collapsedGroups ?? [])
            let groups = window.tabGroups?.map { group in
                SavedTabGroup(id: group.id, name: group.name, color: group.color,
                              collapsed: collapsed.contains(group.id) ? true : nil)
            }
            entry.model.restore(window.tabs, selected: selectedTab(of: window, path: place?.selectedPath,
                                                                    collapsed: collapsed),
                                missing: resolved.missing, groups: groups, closedGroups: window.closedTabGroups,
                                repoKeys: repoKeys)
            return Placed(entry: entry, group: place?.group, tabIndex: place?.tabIndex ?? 0,
                          isSelectedInGroup: place?.isSelectedInGroup ?? true)
        }
        workspaces.append(workspace)
        SessionStore.seed(workspace.key, workspaceFile(for: workspace))
        RecentRepos.workspaces.add(URL(filePath: workspace.key))
        return placed
    }

    /// The offset in `window.tabs` (archived entries included) of the tab at `path`; with none, the first tab outside
    /// a collapsed manual group, so a saved collapse is not undone, else the first.
    private func selectedTab(of window: WorkspaceFile.LiveWindow, path: String?, collapsed: Set<UUID>) -> Int {
        if let path = path.map(WorkspaceFile.standardized),
           let index = window.tabs.firstIndex(where: { $0.path.map(WorkspaceFile.standardized) == path }) {
            return index
        }
        return window.tabs.firstIndex { tab in
            tab.archived != true && (tab.pinned == true || tab.tabGroup.map { !collapsed.contains($0) } ?? true)
        } ?? 0
    }

    /// Lays restored windows out by native tab group: each group in its tab order with its selected window on screen
    /// first, groups front first by number (a window with none after them, each in its own group); the front group ends
    /// up key.
    private func restoreGroups(_ placed: [Placed]) {
        let numbered = Dictionary(grouping: placed.filter { $0.group != nil }) { $0.group ?? 0 }
        let groups = numbered.keys.sorted().map { key in (numbered[key] ?? []).sorted { $0.tabIndex < $1.tabIndex } }
            + placed.filter { $0.group == nil }.map { [$0] }
        // Back to front, so the front group is ordered in last.
        for group in groups.reversed() {
            let windows = group.map(\.entry)
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

    /// The open windows as the session saves them: the Untitled ones, grouped by native tab group, groups front to back
    /// (the front window's group first), each in its tab bar order; then one layout per open workspace, its windows
    /// numbered with the same groups (a native group mixing workspaces stays one), then the layouts of the workspaces
    /// not open now, their groups numbered past every live one. A closing workspace (Close Workspace) counts as not
    /// open; a closed one's layout is kept only while its file is in Recent Workspaces.
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
        var layoutWindows: [ObjectIdentifier: WorkspaceLayout.Window] = [:]
        for (group, members) in ordered.enumerated() {
            for entry in members {
                let window = entry.window
                let tabGroup = window.tabGroup
                let tabIndex = tabGroup?.windows.firstIndex(of: window) ?? 0
                let isSelectedInGroup = tabGroup.map { $0.selectedWindow === window } ?? true
                let model = entry.model
                guard model.workspace == nil else {
                    let collapsed = model.savedTabGroups?.filter { $0.collapsed == true }.map(\.id) ?? []
                    layoutWindows[ObjectIdentifier(entry)] = WorkspaceLayout.Window(
                        id: model.windowID, x: window.frame.minX, y: window.frame.minY, width: window.frame.width,
                        height: window.frame.height, group: group, tabIndex: tabIndex,
                        isSelectedInGroup: isSelectedInGroup,
                        selectedPath: model.savedSelectedPath,
                        collapsedGroups: collapsed.isEmpty ? nil : collapsed)
                    continue
                }
                windows.append(SavedWindow(
                    x: window.frame.minX, y: window.frame.minY, width: window.frame.width, height: window.frame.height,
                    group: group, tabIndex: tabIndex, isSelectedInGroup: isSelectedInGroup,
                    tabs: model.savedTabs, selectedTab: model.savedSelectedIndex, manualTabGroups: model.savedTabGroups,
                    closedTabGroups: model.savedClosedGroups))
            }
        }
        var layouts: [WorkspaceLayout] = []
        for workspace in workspaces where !workspace.isClosing {
            let members = self.windows(of: workspace).compactMap { layoutWindows[ObjectIdentifier($0)] }
            guard !members.isEmpty else { continue }
            layouts.append(WorkspaceLayout(path: workspace.key, open: true, windows: members))
        }
        // The kept layouts' groups after the live ones, in their own order, so a reopened workspace's windows never
        // join an unrelated group that reuses an old number.
        let live = Set(layouts.map(\.path))
        // Both sides standardized alike (`RecentRepos` stores `/private/tmp/…` as `/tmp/…`).
        let recent = Set(RecentRepos.workspaces.urls.map(\.path))
        var kept = workspaceLayouts.filter { layout in
            !live.contains(layout.path)
                && (layout.open || recent.contains(URL(filePath: layout.path).standardizedFileURL.path))
        }
        let numbers = Set(kept.flatMap { $0.windows.map(\.group) }).sorted()
        let renumbered = Dictionary(uniqueKeysWithValues: numbers.enumerated().map { ($1, ordered.count + $0) })
        for index in kept.indices {
            for window in kept[index].windows.indices {
                kept[index].windows[window].group = renumbered[kept[index].windows[window].group] ?? ordered.count
            }
        }
        layouts += kept
        return SavedSession(windows: windows, workspaces: layouts.isEmpty ? nil : layouts)
    }

    /// The windows of `workspace` in its file's order, windows added since appended in the order they opened.
    private func windows(of workspace: Workspace) -> [Entry] {
        let members = entries.filter { $0.model.workspace === workspace }
        var position: [UUID: Int] = [:]
        for (index, id) in workspace.windowOrder.enumerated() where position[id] == nil { position[id] = index }
        let known = members.filter { position[$0.model.windowID] != nil }
            .sorted { (position[$0.model.windowID] ?? 0) < (position[$1.model.windowID] ?? 0) }
        return known + members.filter { position[$0.model.windowID] == nil }
    }

    /// Every open workspace's file as captured now, by identity key, with whether it is read-only; a workspace with no
    /// window is left out (never written empty).
    private func currentWorkspaceFiles() -> [String: (file: WorkspaceFile, isReadOnly: Bool)] {
        var files: [String: (file: WorkspaceFile, isReadOnly: Bool)] = [:]
        for workspace in workspaces where files[workspace.key] == nil && !windows(of: workspace).isEmpty {
            files[workspace.key] = (workspaceFile(for: workspace), workspace.isReadOnly)
        }
        return files
    }

    /// One workspace's file as its windows have it now: their tabs and manual groups, the stored strings of every
    /// unchanged path, the graph view of each tab's repo (`Workspace.views`), the carried-over repos as read, and the
    /// profiles the tabs use. Each profile keeps the file's embedded definition, unless the library's differs from the
    /// one it had when the workspace opened (edited in Settings since; an id with no baseline counts as unedited). An
    /// id the file does not embed takes the library's; one the library lacks keeps the embedded definition.
    private func workspaceFile(for workspace: Workspace) -> WorkspaceFile {
        workspaceFile(for: workspace, windows: windows(of: workspace), fileURL: workspace.url,
                      originals: workspace.originals, carried: workspace.repos)
    }

    /// `workspaceFile(for:)` with these windows, saved at `fileURL` with these stored strings and carried repos (Save
    /// As: the windows that join it, and `WorkspaceFile.rebased`'s results, as `Workspace.rebind` leaves them).
    private func workspaceFile(for workspace: Workspace, windows entries: [Entry], fileURL: URL,
                               originals: [String: WorkspaceFile.Original],
                               carried: [String: WorkspaceFile.Repo]) -> WorkspaceFile {
        let windows = entries.map { entry in
            WorkspaceFile.LiveWindow(
                id: entry.model.windowID,
                tabGroups: entry.model.savedTabGroups?.map { .init(id: $0.id, name: $0.name, color: $0.color) },
                tabs: entry.model.savedTabs, closedTabGroups: entry.model.savedClosedGroups)
        }
        // Every tab's, those in closed groups too.
        let allTabs = windows.flatMap { $0.tabs + ($0.closedTabGroups ?? []).flatMap(\.tabs) }
        let used = Set(allTabs.compactMap { $0.profile?.profileID })
        let store = ProfileLibrary.shared.store
        let profiles = used.compactMap { id -> Profile? in
            let library = store?.profile(id: id)
            guard let embedded = workspace.profiles.first(where: { $0.id == id }) else { return library }
            guard let library, let baseline = workspace.profileBaseline[id], library != baseline else { return embedded }
            return library
        }
        // The views of the tabs' repos (archived and closed ones too); a repo with no view yet gets no entry, so it
        // opens again from its global view.
        let paths = Set(allTabs.compactMap(\.path).map(WorkspaceFile.standardized))
        let views = workspace.views.filter { paths.contains(WorkspaceFile.standardized($0.key)) }
        return WorkspaceFile(windows: windows, views: views, profiles: profiles, carried: carried,
                             originals: originals, repoOrder: workspace.repoOrder, profileOrder: workspace.profileOrder,
                             fileURL: fileURL, homeURL: Workspace.homeURL)
    }

    // MARK: Move a tab to another window

    /// The windows a tab of `model` can move to: every other open window, in `entries` order.
    func moveDestinations(for model: WindowModel) -> [WindowModel] {
        entries.map(\.model).filter { $0 !== model }
    }

    /// Why the tab `id` cannot move from `source` to `destination` now; nil when it can (`moveTab`). No I/O: a menu
    /// builds its entries with it.
    func moveRefusal(_ id: WindowModel.Tab.ID, from source: WindowModel, to destination: WindowModel) -> String? {
        guard let tab = source.tabs.first(where: { $0.id == id }), source !== destination,
              entries.contains(where: { $0.model === source }), entries.contains(where: { $0.model === destination })
        else { return "The tab or the window is gone." }
        // Its profile's definition lives in its workspace file: an Untitled window could not keep it.
        if destination.workspace == nil, source.missingProfile(of: id) != nil { return "Import or pick a profile first" }
        if let workspace = destination.workspace {
            if workspace.isReadOnly { return "\(workspace.name) is read-only" }
            if workspace.writeFailed { return "\(workspace.name) is not being saved" }
        }
        // The tab would stay in the source's unwritten file and come back on its next open.
        if let workspace = source.workspace {
            if workspace.isReadOnly { return "\(workspace.name) is read-only" }
            if workspace.writeFailed { return "\(workspace.name) is not being saved" }
        }
        // A move never empties a workspace (its close burst would write it as it was, with the tab).
        if let workspace = source.workspace, source.tabs.count == 1, source.archivedTabs.isEmpty,
           windows(of: workspace).count == 1 {
            return "Last tab of \(workspace.name) — use Close Workspace"
        }
        // Its stored path belongs to the source file.
        if tab.isMissing { return "Locate the repo first" }
        if tab.archived { return "Unarchive the tab to move it." }
        if tab.isDemo { return "The demo tab stays in its window." }
        // `adopt` would close the tab's session and select the destination's own tab of the repo.
        if let url = tab.repoURL, destination.hasRepo(atPath: url.path) {
            return "\(url.lastPathComponent) is already open in that window"
        }
        return nil
    }

    /// Moves the tab `id` from `source` to `destination` (Move Tab to Window ›, the palette, the drag, the
    /// `-HistqMoveTab` seam), refused before anything changes (`moveRefusal`). The tab goes alone, the source's
    /// multi-selection ends, its session (terminal, AI run) moves along, and it is selected in `destination`. The source
    /// window closes once it is left with no tab, after the tab left it, so its close ends nothing that moved.
    @discardableResult
    func moveTab(_ id: WindowModel.Tab.ID, from source: WindowModel, to destination: WindowModel) -> MoveResult {
        // A close burst still pending is settled first, so its snapshot never writes the tab to the wrong file.
        settleCloseBursts()
        if let reason = moveRefusal(id, from: source, to: destination) { return .refused(reason) }
        source.clearSelection()
        guard let moved = source.detachTab(id) else { return .refused("The tab or the window is gone.") }
        destination.adopt(moved)
        if source.tabs.isEmpty, let entry = entries.first(where: { $0.model === source }) {
            entry.window.close()
            // The source's workspace still has windows (`moveRefusal`): the snapshot its close kept is dropped, and the
            // next pass writes the windows left.
            settleCloseBursts()
        }
        if let window = destination.window { present(window) }
        SessionStore.schedule()
        return .moved
    }

    #if DEBUG
    /// DEBUG `-HistqMoveTab <fromWindow>:<tab>:<toWindow>` (QA of Move Tab to Window): once the launch's windows are
    /// restored and the profiles read, moves tab `<tab>` (an offset in that window's `tabs`) of window `<fromWindow>`
    /// to window `<toWindow>` (offsets in `entries`), without selecting it first, and logs the result to
    /// `operations.txt`.
    private func debugMoveTab(_ spec: String) async {
        _ = await ProfileLibrary.shared.loaded()
        // The restored tabs' repo keys are read off the main thread.
        try? await Task.sleep(for: .milliseconds(500))
        let parts = spec.split(separator: ":").compactMap { Int($0) }
        guard parts.count == 3, entries.indices.contains(parts[0]), entries.indices.contains(parts[2]),
              entries[parts[0]].model.tabs.indices.contains(parts[1])
        else { return RepoMenus.debugLog("move-tab \(spec): bad indices") }
        let source = entries[parts[0]].model
        switch moveTab(source.tabs[parts[1]].id, from: source, to: entries[parts[2]].model) {
        case .moved: RepoMenus.debugLog("move-tab \(spec): moved")
        case .refused(let reason): RepoMenus.debugLog("move-tab \(spec): refused \(reason)")
        }
    }
    #endif

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

    /// The native tab bar's "+": a new window with a Welcome tab, as the next native tab of `window`'s group, in
    /// `window`'s workspace.
    private func openNativeTab(of window: NSWindow) {
        let entry = newWindow(workspace: self.entry(for: window)?.model.workspace)
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
        // Never under the onboarding (its tour's demo tab keeps the selection): the folders open once it ends.
        if entry.model.isOnboarding {
            entry.model.openAfterOnboarding(folders)
        } else {
            for folder in folders { entry.model.openTab(folder) }
        }
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

    /// A window with unsaved edits in a tab stays open: its leave prompt shows, and its Save or Don't Save closes the
    /// window again.
    func windowShouldClose(_ sender: NSWindow) -> Bool {
        guard let entry = entry(for: sender) else { return true }
        return !revealUnsavedTab(in: [entry]) { [weak sender] in sender?.performClose(nil) }
    }

    /// A close or quit of `entries`' windows: the first one with unsaved edits in a tab comes forward and shows that
    /// tab with its leave prompt (`WindowModel.revealUnsavedTab`), whose Save or Don't Save runs `retry`. True when it
    /// asked: the close or quit waits.
    private func revealUnsavedTab(in entries: [Entry], retry: @escaping @MainActor () -> Void) -> Bool {
        let unsaved = entries.first { entry in entry.model.sessions.values.contains { $0.hasUnsavedEdits } }
        guard let entry = unsaved else { return false }
        present(entry.window)
        return entry.model.revealUnsavedTab(in: entry.model.tabs.map(\.id), retry: retry)
    }

    func windowWillClose(_ notification: Notification) {
        guard let window = notification.object as? NSWindow else { return }
        let model = entries.first { $0.window === window }?.model
        // An open palette holds row closures over the window's sessions; drop it so they are freed with the window.
        model?.closePalette()
        // The closed window's views can keep its sessions (and their AI runs and chats) alive a while: a running AI
        // job or chat turn stops now, before it sends the diff.
        model?.sessions.values.forEach {
            $0.closeAI()
            $0.stopAIChat()
        }
        // Closing a window never calls the sessions' `close()`: their shells end here.
        model?.sessions.values.forEach { $0.endTerminal() }
        // Its onboarding ends, not done (it shows again by itself when nothing else changed): the demo tab closes and
        // its repository is removed. Folders opened meanwhile are dropped with the window.
        model?.endOnboarding(openingQueued: false)
        // Before it leaves `entries`: the first window of a workspace closed by hand keeps the file as it was.
        if let workspace = model?.workspace { keepPreCloseSnapshot(of: workspace) }
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

    /// New Window (⇧⌘N): in the target window's workspace.
    @objc func newWindowAction(_ sender: Any?) {
        guard !isOnboarding(for: #selector(newWindowAction(_:))) else { return }
        show(newWindow(workspace: target()?.model.workspace))
    }

    @objc func newTab(_ sender: Any?) {
        guard !isOnboarding(for: #selector(newTab(_:))) else { return }
        guard let entry = target() else { return show(newWindow()) }
        entry.model.openTab(nil)
        show(entry)
    }

    @objc func openDocument(_ sender: Any?) {
        guard !isOnboarding(for: #selector(openDocument(_:))) else { return }
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
        guard !isOnboarding(for: #selector(cloneRepository(_:))) else { return }
        newTab(sender)
    }

    /// Asks for a patch file and opens the Apply Patch preview on it, in the key window's repo tab.
    @objc func applyPatch(_ sender: Any?) {
        guard !isOnboarding(for: #selector(applyPatch(_:))) else { return }
        patchSession()?.chooseAndPreviewPatch()
    }

    /// Opens the Apply Patch preview on the clipboard's text, in the key window's repo tab.
    @objc func applyClipboardPatch(_ sender: Any?) {
        guard !isOnboarding(for: #selector(applyClipboardPatch(_:))) else { return }
        patchSession()?.previewClipboardPatch()
    }

    /// The selected repo tab a patch can be applied in: no modal, Settings or palette over it, no operation in
    /// progress.
    private func patchSession() -> RepoSession? {
        guard let model = target()?.model, !model.isShowingModal, let session = model.actionSession,
              session.repoState?.isOperationInProgress != true
        else { return nil }
        return session
    }

    /// File › Save (⌘S): saves the key window's file editor. A menu item, not a view shortcut: the hidden kept-alive
    /// tabs stay mounted, and one of them could take it.
    @objc func saveEditedFile(_ sender: Any?) {
        editorSession()?.saveEditor()
    }

    /// The key window's selected repo tab whose file editor has unsaved text and no save in flight, with no modal,
    /// Settings or palette over it.
    private func editorSession() -> RepoSession? {
        guard let model = entry(for: NSApp.keyWindow)?.model, !model.isShowingModal, let session = model.actionSession,
              let editor = session.editor, editor.isDirty, !editor.saving
        else { return nil }
        return session
    }

    /// Closes the key window's selected tab, and the window with its last tab.
    @objc func closeTab(_ sender: Any?) {
        guard !isOnboarding(for: #selector(closeTab(_:))) else { return }
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
        guard !isOnboarding(for: #selector(reopenClosedTab(_:))) else { return }
        guard let entry = entry(for: NSApp.keyWindow) else { return }
        entry.model.reopenClosedTab()
    }

    /// ⌘K: opens the key window's command palette, or closes it. A main menu item, so it works wherever the focus is
    /// (the AppKit toolbar, a table, the palette's own field).
    @objc func toggleCommandPalette(_ sender: Any?) {
        guard !isOnboarding(for: #selector(toggleCommandPalette(_:))) else { return }
        guard let entry = target() else { return }
        entry.model.togglePalette()
    }

    /// Opens the Settings modal in the key window (⌘,); it stays open when it already shows.
    @objc func showSettings() {
        guard !isOnboarding(for: #selector(showSettings)) else { return }
        let entry = target() ?? newWindow()
        entry.model.openSettings()
        show(entry)
    }

    /// Help › Show Onboarding…: starts it at the welcome card on the target window (a new one when none is open). A
    /// window that runs it already only comes forward, on its current step: never a second one. Not refused while it
    /// runs, as it never doubles.
    @objc func showOnboarding(_ sender: Any?) {
        if let running = entries.first(where: { $0.model.isOnboarding }) {
            show(running)
            return
        }
        let entry = target() ?? newWindow()
        entry.model.startOnboarding(at: .welcome)
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
        guard !isOnboarding(for: #selector(toggleTerminal(_:))) else { return }
        target()?.model.toggleTerminal()
    }

    /// View › Move Tabs to the Left/Top: writes General › Tab position, as the palette command does; the windows
    /// follow it live.
    @objc func toggleTabPosition(_ sender: Any?) {
        guard !isOnboarding(for: #selector(toggleTabPosition(_:))) else { return }
        let next: TabPosition = TabPosition.current == .left ? .top : .left
        Preferences.defaults.set(next.rawValue, forKey: PrefKey.tabPosition.rawValue)
    }

    /// View › Classic / Stacked / Columns / Focus (the item's `representedObject`): Focus again (⌥⌘F) leaves Focus.
    /// The windows follow it live, and their minimum size (Columns' is wider).
    @objc func chooseLayout(_ sender: NSMenuItem) {
        guard !isOnboarding(for: #selector(chooseLayout(_:))) else { return }
        guard let preset = (sender.representedObject as? String).flatMap(LayoutPreset.init(rawValue:)) else { return }
        LayoutPreset.choose(preset)
    }

    /// View › Reset Layout: default panel widths and Stacked split; the layout preset stays.
    @objc func resetLayout(_ sender: Any?) {
        guard !isOnboarding(for: #selector(resetLayout(_:))) else { return }
        LayoutPreset.reset()
    }

    @objc func checkForUpdates(_ sender: Any?) {
        updater.checkForUpdates()
    }

    // MARK: Workspaces

    /// A workspace file's extension.
    private static let workspaceExtension = "histqws"

    /// The workspace file type the panels show.
    private static var workspaceType: UTType {
        UTType(filenameExtension: workspaceExtension, conformingTo: .json) ?? .json
    }

    /// File › New Workspace: asks where to save it, writes a workspace with one window and a Welcome tab, then opens
    /// that window.
    @objc func newWorkspace(_ sender: Any?) {
        guard !isOnboarding(for: #selector(newWorkspace(_:))) else { return }
        let panel = workspaceSavePanel(name: "Untitled", folder: nil)
        Task { @MainActor in
            guard await panel.begin() == .OK, let url = panel.url else { return }
            self.createWorkspace(at: url)
        }
    }

    /// File › Open Workspace…: asks for a workspace file and opens it.
    @objc func openWorkspaceDocument(_ sender: Any?) {
        guard !isOnboarding(for: #selector(openWorkspaceDocument(_:))) else { return }
        let panel = NSOpenPanel()
        panel.canChooseDirectories = false
        panel.canChooseFiles = true
        panel.allowsMultipleSelection = false
        panel.allowedContentTypes = [Self.workspaceType]
        panel.prompt = "Open"
        Task { @MainActor in
            guard await panel.begin() == .OK, let url = panel.url else { return }
            self.openWorkspace(url)
        }
    }

    /// Recent Workspaces › a file (the item's `representedObject`, its URL).
    @objc func openRecentWorkspace(_ sender: NSMenuItem) {
        guard !isOnboarding(for: #selector(openRecentWorkspace(_:))) else { return }
        guard let url = sender.representedObject as? URL else { return }
        openWorkspace(url)
    }

    /// Recent Workspaces › Clear Menu.
    @objc func clearRecentWorkspaces(_ sender: Any?) {
        guard !isOnboarding(for: #selector(clearRecentWorkspaces(_:))) else { return }
        RecentRepos.workspaces.clear()
    }

    /// File › Recent Workspaces as it opens: the files opened lately, most recent first (a pick opens it), then Clear
    /// Menu. Built from the list in memory, never checking the disk.
    func menuNeedsUpdate(_ menu: NSMenu) {
        guard menu === recentWorkspacesMenu else { return }
        menu.removeAllItems()
        for url in RecentRepos.workspaces.urls {
            let item = menu.addItem(withTitle: url.deletingPathExtension().lastPathComponent,
                                    action: #selector(openRecentWorkspace(_:)), keyEquivalent: "")
            item.target = self
            item.representedObject = url
            item.toolTip = (url.path as NSString).abbreviatingWithTildeInPath
        }
        if menu.numberOfItems > 0 { menu.addItem(.separator()) }
        menu.addItem(withTitle: "Clear Menu", action: #selector(clearRecentWorkspaces(_:)), keyEquivalent: "")
            .target = self
    }

    /// File › Save Workspace As…: asks for the new file, then saves the target window's workspace there (from an
    /// Untitled window, every Untitled window), `saveWorkspace(to:from:)`.
    @objc func saveWorkspaceAs(_ sender: Any?) {
        guard !isOnboarding(for: #selector(saveWorkspaceAs(_:))) else { return }
        guard let entry = target() else { return }
        let workspace = entry.model.workspace
        let panel = workspaceSavePanel(name: workspace?.name ?? "Untitled",
                                       folder: workspace?.url.deletingLastPathComponent())
        Task { @MainActor in
            guard await panel.begin() == .OK, let url = panel.url else { return }
            self.saveWorkspace(to: url, from: entry)
        }
    }

    /// File › Close Workspace: closes the target window's workspace with all its windows.
    @objc func closeWorkspace(_ sender: Any?) {
        guard !isOnboarding(for: #selector(closeWorkspace(_:))) else { return }
        guard let workspace = target()?.model.workspace else { return }
        close(workspace)
    }

    /// Opens the workspace file at `url`, or brings its front window forward when it is open already (same identity
    /// key: a symlink or another spelling of the path is the same file). Returns at once: the file is read off the main
    /// thread, then its windows are restored; an open of the same file in flight makes this one a no-op. A file that
    /// cannot be read shows an alert and nothing is written; one with keys this build would drop opens read-only.
    func openWorkspace(_ url: URL) {
        Task { @MainActor in
            let key = await Task.detached { WorkspaceFile.identityKey(for: url) }.value
            settleCloseBursts()
            if let open = workspaces.first(where: { $0.key == key }) { return bringForward(open) }
            guard !openingKeys.contains(key) else { return }
            openingKeys.insert(key)
            defer { openingKeys.remove(key) }
            do {
                let (workspace, resolved, repoKeys) = try await Workspace.open(url)
                if let open = workspaces.first(where: { $0.key == workspace.key }) { return bringForward(open) }
                restoreGroups(restoreWindows(of: workspace, resolved, repoKeys: repoKeys))
                offerProfileImport(workspace)
            } catch {
                let reason = error.localizedDescription
                Self.logger.error("workspace not opened: \(key, privacy: .private): \(reason, privacy: .public)")
                // The alert needs a window: a launch whose only file failed shows the Welcome window.
                if entries.isEmpty { show(newWindow()) }
                showAlert("\"\(url.lastPathComponent)\" could not be opened.", Self.message(for: error))
            }
        }
    }

    /// Once `workspace`'s windows show (called once per open, after `restoreGroups`): when the profiles its tabs use
    /// include some the file defines and Settings › Profiles lacks (the badge's condition,
    /// `WindowModel.missingProfile(of:)`), its front window offers to import them (`ProfileImportSheet`). Nothing is
    /// offered when the profiles file cannot be read, the workspace closed meanwhile or the window shows a modal.
    private func offerProfileImport(_ workspace: Workspace) {
        Task { @MainActor in
            guard await ProfileLibrary.shared.loaded() != nil,
                  workspaces.contains(where: { $0 === workspace }), !workspace.isClosing else { return }
            let members = windows(of: workspace)
            var seen = Set<UUID>()
            let missing = members.flatMap { entry in
                entry.model.tabs.compactMap { entry.model.missingProfile(of: $0.id)?.embedded }
            }.filter { seen.insert($0.id).inserted }
            // The front one on screen: a native tab not selected in its group would hide the sheet.
            let front = NSApp.orderedWindows.lazy.compactMap { window in
                members.first { $0.window === window && window.isVisible }
            }.first
            guard !missing.isEmpty, let entry = front ?? members.first(where: { $0.window.isVisible }),
                  entry.model.modal == nil else { return }
            entry.model.presentModal(.importProfiles(missing))
            #if DEBUG
            // `-HistqImportProfiles YES`: accepts the sheet as its Import button does, once it has shown.
            if AppState.launchFlag("-HistqImportProfiles") == "YES" {
                try? await Task.sleep(for: .seconds(1))
                guard case .importProfiles? = entry.model.modal else { return }
                entry.model.closeModal()
                ProfileImportSheet.importProfiles(missing, into: workspace)
            }
            #endif
        }
    }

    /// Shows the front window of `workspace` (it was opened again) and moves its file up in Recent Workspaces.
    private func bringForward(_ workspace: Workspace) {
        RecentRepos.workspaces.add(URL(filePath: workspace.key))
        let members = windows(of: workspace)
        let front = NSApp.orderedWindows.lazy.compactMap { window in members.first { $0.window === window } }.first
        if let entry = front ?? members.first { show(entry) }
    }

    /// New Workspace at `url`: the file, with one window and a Welcome tab, is written first; only then does the window
    /// open in it.
    private func createWorkspace(at url: URL) {
        settleCloseBursts()
        guard canSaveWorkspace(to: url, as: nil) else { return }
        let workspace = Workspace(url: url)
        let windowID = UUID()
        workspace.windowOrder = [windowID]
        let file = WorkspaceFile(windows: [.init(id: windowID, tabs: [SavedTab()])], views: [:], profiles: [],
                                 carried: [:], originals: [:], repoOrder: [], profileOrder: [], fileURL: url,
                                 homeURL: Workspace.homeURL)
        guard writeWorkspace(file, to: url) else { return }
        let entry = newWindow(workspace: workspace)
        entry.model.windowID = windowID
        workspaces.append(workspace)
        RecentRepos.workspaces.add(URL(filePath: workspace.key))
        show(entry)
    }

    /// Save Workspace As… to `url` from `entry`'s window. From a workspace window, that workspace is written there and
    /// rebound to it (every path relative to the new folder; the old file keeps its last content); from an Untitled
    /// window, every Untitled window joins a new workspace written there. The file is written first: on failure an
    /// alert names the error and every window stays where it was.
    private func saveWorkspace(to url: URL, from entry: Entry) {
        settleCloseBursts()
        guard entries.contains(where: { $0 === entry }) else { return }
        if let workspace = entry.model.workspace {
            guard workspaces.contains(where: { $0 === workspace }), !workspace.isClosing,
                  canSaveWorkspace(to: url, as: workspace)
            else { return }
            let rebased = WorkspaceFile.rebased(originals: workspace.originals, missing: workspace.missing,
                                                carried: workspace.repos, fileURL: url, homeURL: Workspace.homeURL)
            let file = workspaceFile(for: workspace, windows: windows(of: workspace), fileURL: url,
                                     originals: rebased.originals, carried: rebased.carried)
            guard writeWorkspace(file, to: url) else { return }
            workspace.rebind(to: url)
            RecentRepos.workspaces.add(URL(filePath: workspace.key))
            SessionStore.schedule()
        } else {
            guard canSaveWorkspace(to: url, as: nil) else { return }
            let untitled = entries.filter { $0.model.workspace == nil }
            let workspace = Workspace(url: url)
            workspace.windowOrder = untitled.map(\.model.windowID)
            let file = workspaceFile(for: workspace, windows: untitled, fileURL: url, originals: workspace.originals,
                                     carried: workspace.repos)
            guard writeWorkspace(file, to: url) else { return }
            workspaces.append(workspace)
            for entry in untitled { entry.model.join(workspace) }
            RecentRepos.workspaces.add(URL(filePath: workspace.key))
        }
    }

    /// Whether `url` may become the file of `workspace` (nil: a new one): not the file of another open workspace, nor
    /// one being opened. Shows an alert when not.
    private func canSaveWorkspace(to url: URL, as workspace: Workspace?) -> Bool {
        let key = WorkspaceFile.identityKey(for: url)
        guard openingKeys.contains(key) || workspaces.contains(where: { $0.key == key && $0 !== workspace }) else {
            return true
        }
        showAlert("\"\(url.lastPathComponent)\" is open as another workspace.",
                  "Close that workspace first, or choose another file.")
        return false
    }

    /// Writes a new workspace file now (Save As, New Workspace); false, with an alert naming the error, on failure.
    private func writeWorkspace(_ file: WorkspaceFile, to url: URL) -> Bool {
        do {
            try SessionStore.writeNow(file, to: url)
            return true
        } catch {
            let reason = error.localizedDescription
            Self.logger.error("workspace not saved: \(reason, privacy: .public)")
            showAlert("\"\(url.lastPathComponent)\" could not be saved.", Self.message(for: error))
            return false
        }
    }

    /// Close Workspace: its file is written one last time with every window (then never again), its layout is kept
    /// with `open: false` (it stays closed at the next launch), and its windows close without capturing anything. A tab
    /// with unsaved edits in one of its windows stops it first (its windows close without `windowShouldClose`): its
    /// leave prompt shows, and its Save or Don't Save closes the workspace again.
    private func close(_ workspace: Workspace) {
        if revealUnsavedTab(in: windows(of: workspace), retry: { [weak self] in self?.close(workspace) }) { return }
        settleCloseBursts()
        guard workspaces.contains(where: { $0 === workspace }), !workspace.isClosing else { return }
        let members = windows(of: workspace)
        workspace.preCloseSnapshot = nil
        if let layout = currentSession().workspaces?.first(where: { $0.path == workspace.key }) {
            keepClosedLayout(layout)
        }
        workspace.isClosing = true
        SessionStore.finish(workspace.key)
        workspaces.removeAll { $0 === workspace }
        // Its tabs save no view as they close: not to the file just finished, never to the global files.
        for entry in members {
            for session in entry.model.sessions.values { session.viewRoute = .dropped }
        }
        for entry in members { entry.window.close() }
    }

    /// Keeps `layout` in `workspaceLayouts` as a closed workspace's (`open: false`), replacing any entry of its file.
    private func keepClosedLayout(_ layout: WorkspaceLayout) {
        var layout = layout
        layout.open = false
        workspaceLayouts.removeAll { $0.path == layout.path }
        workspaceLayouts.append(layout)
    }

    /// Keeps `workspace`'s file and layout as they are now, before one of its windows closes by hand (or ⌘W, a tab's
    /// close button or Close Tabs empties it), unless a snapshot is kept already (a burst of closes keeps its first),
    /// the workspace is closing or quit has begun.
    private func keepPreCloseSnapshot(of workspace: Workspace) {
        guard !isTerminating, !workspace.isClosing, workspace.preCloseSnapshot == nil,
              workspaces.contains(where: { $0 === workspace }),
              let layout = currentSession().workspaces?.first(where: { $0.path == workspace.key })
        else { return }
        workspace.preCloseSnapshot = (workspaceFile(for: workspace), layout)
    }

    /// Settles the close bursts, before a capture: a workspace left with no window since its `preCloseSnapshot` was
    /// kept counts as closed — the snapshot's file (every window it had) goes to the next write pass, its layout is
    /// kept with `open: false` and it leaves `workspaces`, so it is never written with fewer windows; one with windows
    /// left drops its snapshot, and the pass writes the windows left.
    private func settleCloseBursts() {
        for workspace in workspaces {
            guard let snapshot = workspace.preCloseSnapshot else { continue }
            workspace.preCloseSnapshot = nil
            guard windows(of: workspace).isEmpty else { continue }
            keepClosedLayout(snapshot.layout)
            settledFiles[workspace.key] = (snapshot.file, workspace.isReadOnly)
            workspaces.removeAll { $0 === workspace }
        }
    }

    /// A save panel for a workspace file named `name`, in `folder` when given.
    private func workspaceSavePanel(name: String, folder: URL?) -> NSSavePanel {
        let panel = NSSavePanel()
        panel.allowedContentTypes = [Self.workspaceType]
        panel.nameFieldStringValue = "\(name).\(Self.workspaceExtension)"
        if let folder { panel.directoryURL = folder }
        return panel
    }

    /// A warning alert as a sheet on the target window (none: logged only), so it never blocks the app.
    private func showAlert(_ message: String, _ detail: String) {
        guard let window = target()?.window else {
            return Self.logger.error("alert not shown, no window: \(message, privacy: .private)")
        }
        let alert = NSAlert()
        alert.alertStyle = .warning
        alert.messageText = message
        alert.informativeText = detail
        alert.beginSheetModal(for: window)
    }

    /// Why a workspace file could not be read or written, for an alert.
    private static func message(for error: Error) -> String {
        guard let error = error as? WorkspaceFile.FileError else { return error.localizedDescription }
        return switch error {
        case .unsupportedVersion(let version):
            "It was saved by another version of Histq (workspace format \(version)) and is left unchanged."
        case .undecodable: "It is not a Histq workspace file."
        case .empty: "A workspace needs a window with at least one tab."
        }
    }

    // MARK: Onboarding

    /// The main-menu actions a window's onboarding refuses, its cards and its tour alike: every window-scoped one (tabs,
    /// Open…, Clone…, Apply Patch…, the palette, new window, the workspace items, Settings…, Find, Show Terminal, Move
    /// Tabs, the layout presets, Reset Layout), in `validateMenuItem` and in each action (a key equivalent the menu
    /// missed). Quit, Hide, About, Check for Updates, the Edit text commands, Close Window (which ends the onboarding),
    /// Minimize and Zoom stay live. Customize Toolbar is off through the toolbar (`HeaderToolbar`), Undo / Redo
    /// through the graph table that answers them (`GraphTableView`, via `isOnboarding(in:)`).
    private static let refusedWhileOnboarding: Set<Selector> = [
        #selector(newWindowAction(_:)), #selector(newTab(_:)), #selector(openDocument(_:)),
        #selector(cloneRepository(_:)), #selector(applyPatch(_:)), #selector(applyClipboardPatch(_:)),
        #selector(closeTab(_:)), #selector(reopenClosedTab(_:)), #selector(toggleCommandPalette(_:)),
        #selector(showSettings), #selector(toggleTerminal(_:)), #selector(toggleTabPosition(_:)),
        #selector(chooseLayout(_:)), #selector(resetLayout(_:)), #selector(newWorkspace(_:)),
        #selector(openWorkspaceDocument(_:)), #selector(openRecentWorkspace(_:)), #selector(clearRecentWorkspaces(_:)),
        #selector(saveWorkspaceAs(_:)), #selector(closeWorkspace(_:)), #selector(findCommits(_:)),
    ]

    /// Whether `action` is refused now: it is one of `refusedWhileOnboarding` and the window it acts on runs the
    /// onboarding (the key window for ⌘W and ⇧⌘T, as they act on it; `target()` for the others). Settings opened from
    /// a card covers it: ⌘W and ⌘F then act on Settings as they always do (close it, search it), never on the tabs.
    private func isOnboarding(for action: Selector?) -> Bool {
        guard let action, Self.refusedWhileOnboarding.contains(action) else { return false }
        let actsOnKey = action == #selector(closeTab(_:)) || action == #selector(reopenClosedTab(_:))
        guard let model = actsOnKey ? entry(for: NSApp.keyWindow)?.model : target()?.model, model.isOnboarding else {
            return false
        }
        let actsOnSettings = action == #selector(closeTab(_:)) || action == #selector(findCommits(_:))
        return !(actsOnSettings && model.isSettingsOpen)
    }

    /// Whether the onboarding runs over `window`: for the views that validate nil-targeted menu items themselves
    /// (`GraphTableView`'s Undo / Redo), which reach it through `NSApp.delegate`.
    func isOnboarding(in window: NSWindow?) -> Bool {
        entry(for: window)?.model.isOnboarding == true
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
        guard !isOnboarding(for: #selector(findCommits(_:))) else { return }
        // Settings (with no modal over it) searches its own rows.
        if let model = target()?.model, model.canFindInSettings {
            model.findInSettings()
            return
        }
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
        // Titles and checkmarks first: the onboarding's steps write these preferences while the items are refused.
        if menuItem.action == #selector(toggleTabPosition(_:)) {
            menuItem.title = TabPosition.current == .left ? "Move Tabs to the Top" : "Move Tabs to the Left"
        }
        if menuItem.action == #selector(chooseLayout(_:)) {
            menuItem.state = menuItem.representedObject as? String == LayoutPreset.current.rawValue ? .on : .off
        }
        if isOnboarding(for: menuItem.action) { return false }
        if menuItem.action == #selector(closeTab(_:)) { return NSApp.keyWindow != nil }
        if menuItem.action == #selector(saveEditedFile(_:)) { return editorSession() != nil }
        // Close Workspace only on a workspace window; Save Workspace As… on any window (an Untitled one saves every
        // Untitled window).
        if menuItem.action == #selector(closeWorkspace(_:)) { return target()?.model.workspace != nil }
        if menuItem.action == #selector(saveWorkspaceAs(_:)) { return target() != nil }
        if menuItem.action == #selector(clearRecentWorkspaces(_:)) { return !RecentRepos.workspaces.urls.isEmpty }
        if menuItem.action == #selector(reopenClosedTab(_:)) {
            return entry(for: NSApp.keyWindow)?.model.canReopenClosedTab ?? false
        }
        if menuItem.action == #selector(checkForUpdates(_:)) {
            // Disabled while the updater is off (no update signing key in this build, or a Debug build).
            menuItem.title = updater.menuTitle
            menuItem.toolTip = updater.canCheckForUpdates ? nil : "Updates are off in this build."
            return updater.canCheckForUpdates
        }
        if menuItem.action == #selector(applyPatch(_:)) || menuItem.action == #selector(applyClipboardPatch(_:)) {
            return patchSession() != nil
        }
        if menuItem.action == #selector(findCommits(_:)) {
            if target()?.model.canFindInSettings == true { return true }
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
        return true
    }

    /// App menu (About, Check for Updates, Settings, Hide, Quit), File, Edit, View (the terminal, the tab position, the layout presets), Window and
    /// Help (Show Onboarding…; macOS adds its search field) menus: without Edit, text fields lose copy and paste.
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
        fileMenu.addItem(withTitle: "Apply Patch…", action: #selector(applyPatch(_:)), keyEquivalent: "").target = self
        fileMenu.addItem(withTitle: "Apply Patch from Clipboard", action: #selector(applyClipboardPatch(_:)),
                         keyEquivalent: "").target = self
        fileMenu.addItem(withTitle: "Command Palette…", action: #selector(toggleCommandPalette(_:)), keyEquivalent: "k")
            .target = self
        // ⌘P opens the palette too: hidden, so the menu shows only ⌘K.
        let paletteItem = fileMenu.addItem(withTitle: "Command Palette…", action: #selector(toggleCommandPalette(_:)),
                                           keyEquivalent: "p")
        paletteItem.target = self
        paletteItem.isHidden = true
        paletteItem.allowsKeyEquivalentWhenHidden = true
        fileMenu.addItem(.separator())
        fileMenu.addItem(withTitle: "New Workspace", action: #selector(newWorkspace(_:)), keyEquivalent: "")
            .target = self
        fileMenu.addItem(withTitle: "Open Workspace…", action: #selector(openWorkspaceDocument(_:)), keyEquivalent: "")
            .target = self
        recentWorkspacesMenu.delegate = self
        fileMenu.addItem(withTitle: "Recent Workspaces", action: nil, keyEquivalent: "").submenu = recentWorkspacesMenu
        fileMenu.addItem(withTitle: "Save Workspace As…", action: #selector(saveWorkspaceAs(_:)), keyEquivalent: "")
            .target = self
        fileMenu.addItem(withTitle: "Close Workspace", action: #selector(closeWorkspace(_:)), keyEquivalent: "")
            .target = self
        fileMenu.addItem(.separator())
        fileMenu.addItem(withTitle: "Save", action: #selector(saveEditedFile(_:)), keyEquivalent: "s").target = self
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
        for preset in [LayoutPreset.classic, .stacked, .columns, .focus] {
            let item = viewMenu.addItem(withTitle: preset.rawValue.capitalized, action: #selector(chooseLayout(_:)),
                                        keyEquivalent: preset == .focus ? "f" : "")
            item.keyEquivalentModifierMask = [.command, .option]
            item.representedObject = preset.rawValue
            item.target = self
        }
        viewMenu.addItem(withTitle: "Reset Layout", action: #selector(resetLayout(_:)), keyEquivalent: "").target = self
        viewMenu.addItem(.separator())
        // Target nil: AppKit enables it only when the key window has a customizable toolbar.
        viewMenu.addItem(withTitle: "Customize Toolbar…",
                         action: #selector(NSWindow.runToolbarCustomizationPalette(_:)), keyEquivalent: "")
        let windowMenu = NSMenu(title: "Window")
        windowMenu.addItem(withTitle: "Minimize", action: #selector(NSWindow.performMiniaturize(_:)), keyEquivalent: "m")
        windowMenu.addItem(withTitle: "Zoom", action: #selector(NSWindow.performZoom(_:)), keyEquivalent: "")
        NSApp.windowsMenu = windowMenu
        let helpMenu = NSMenu(title: "Help")
        helpMenu.addItem(withTitle: "Show Onboarding…", action: #selector(showOnboarding(_:)), keyEquivalent: "")
            .target = self
        NSApp.helpMenu = helpMenu
        let mainMenu = NSMenu()
        for submenu in [appMenu, fileMenu, editMenu, viewMenu, windowMenu, helpMenu] {
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
