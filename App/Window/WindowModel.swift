// One window's tabs: each is a repo, or a Welcome tab (no repo), with the selection, the page the window shows and
// the Settings modal over it.
import AppKit
import HistqCore
import os

/// One window's tabs: each is a repo, or a Welcome tab (no repo). The `TabStrip` under the toolbar draws them, the
/// toolbar's repo menu lists them. A repo tab has
/// a `RepoSession`, created when the tab is opened or selected and dropped when it closes; selecting a tab goes
/// through its session's `select`, so the tab's detail shows its placeholder in the same frame.
@Observable
@MainActor
final class WindowModel {
    struct Tab: Identifiable, Equatable {
        let id = UUID()
        /// The repo's folder; nil for a Welcome tab. Its profile lives in its `RepoSession` (`profileID`), which runs
        /// the git commands that use it.
        var repoURL: URL?
        /// A restored repo whose folder is gone or no longer a git repository: the tab shows "Repo not found" (Locate,
        /// Remove) and gets no session.
        var isMissing = false
        /// The repository's git common dir (`RepoGroupKey`), shared by its worktrees' tabs; nil until read (off the main
        /// thread) or for a Welcome tab. Tabs with the same key are kept side by side, as a group.
        var repoKey: String?
        /// The name the user gave the tab (its menu's Set Alias…); nil shows the folder's name.
        var alias: String?
        /// The emoji the user gave the tab (its menu's Set Emoji…), one `Character`; nil shows none.
        var emoji: String?
        /// The tab sits in the pinned area at the far left (`pinnedCount`); a worktree group is pinned whole.
        var pinned = false
        /// The color of the tab's book icon (its menu's Icon Color), an index into `Palette.graphLanes`; nil draws it in
        /// the text's color. Shown when the tab has no emoji, pinned or not.
        var iconColor: Int?
        /// The archived tab popped out beside the archive button (`openArchived(at:)`): always the last of `tabs`, at
        /// most one, never pinned and never in a group (its `repoKey` stays nil).
        var archived = false

        /// The alias, else the repo folder's name, or "New Tab" for a Welcome tab.
        var title: String { alias ?? repoURL?.lastPathComponent ?? "New Tab" }
    }

    /// A closed repo tab that ⇧⌘T reopens: as the session saves it, its group, and its index when it closed.
    private struct ClosedTab {
        let saved: SavedTab
        let repoKey: String?
        let index: Int
    }

    /// The repo tabs closed in this window, last closed last; ⇧⌘T reopens them one by one.
    @ObservationIgnored private var closedTabs: [ClosedTab] = []
    private static let closedTabsLimit = 25

    private(set) var tabs: [Tab] = [Tab()]
    /// The window's archive: the stowed archived tabs, most recently archived first, each saved with `archived` set.
    /// They have no `Tab` and no session; `openArchived(at:)` pops one out as the last of `tabs`. Observed: the session
    /// saves them (`savedTabs`).
    private(set) var archivedTabs: [SavedTab] = []
    private(set) var selectedTabID: Tab.ID? {
        didSet {
            expandSelectedGroup()
            // A hidden tab holds its watcher's refreshes; the shown one reads what it held (`RepoSession.isShown`).
            guard oldValue != selectedTabID else { return }
            oldValue.flatMap { sessions[$0] }?.isShown = false
            selectedTabID.flatMap { sessions[$0] }?.isShown = true
            // The new tab's session may not exist yet (`activateSelectedTab` makes it next): it goes first anyway.
            if let selectedTabID {
                let older = recentlyShown.filter { $0 != selectedTabID && sessions[$0] != nil }
                recentlyShown = [selectedTabID] + older.prefix(Self.keptLayouts - 1)
            }
        }
    }
    /// The tabs shown last, most recent first: `TabContent` keeps the layouts of those with a session mounted (hidden
    /// but the selected one), so a switch back shows the tab as it was without building it again. Pruned when a tab
    /// closes or is archived (`remove(at:)`).
    private(set) var recentlyShown: [Tab.ID] = []
    /// At most this many repo layouts stay mounted: each holds its graph table, diff and detail views, so the memory
    /// a window takes stays bounded however many tabs it has. 4 covers going back and forth between a few repos.
    private static let keptLayouts = 4
    /// The tab groups (by key) collapsed with a click on their name, as Chrome's: only the name shows. The selected
    /// tab is never in one: a group opens again when one of its tabs is selected (the tab list, ⇧⌘T, a worktree).
    private(set) var collapsedGroups: Set<String> = []
    /// The repo tabs' sessions, by tab.
    private(set) var sessions: [Tab.ID: RepoSession] = [:]
    /// The Welcome tabs' state (the clone in flight, the git check), by tab: it outlives the view across tab
    /// switches. Created on first use by `welcome(for:)`.
    @ObservationIgnored private var welcomes: [Tab.ID: WelcomeModel] = [:]
    /// Session restore: the saved profile and commit of restored tabs that have no session yet (sessions are made on
    /// first select), applied when it is made; until then the next save keeps them as they were. Observed: a profile
    /// picked in such a tab's menu (`setProfile`) redraws its dot and saves the session.
    private var restored: [Tab.ID: SavedTab] = [:]
    /// The page the window shows: the selected tab (`.home`).
    let navigation = Navigation()
    /// The Settings modal shows over the page (task 9.7). Read only by `ModalHost`, the toolbar and the backdrop
    /// modifier, so opening it never re-evaluates `MainView`.
    private(set) var isSettingsOpen = false
    /// The Settings modal's section, kept while it is closed.
    private(set) var settingsSection: SettingsSection = .general
    /// Changes with every `selectSettings`, even of the same section: the section's placeholder and content lines
    /// follow it.
    private(set) var settingsToken = 0
    /// Changes with each ⌘F while Settings shows (`findInSettings`): its header's search opens and takes the focus.
    private(set) var settingsSearchToken = 0
    /// The open command palette; nil while closed. Read only by `CommandPaletteOverlay` and `MainView`'s backdrop
    /// modifier, so opening it never re-evaluates `MainView`'s body.
    private(set) var palette: CommandPaletteModel?
    /// The window's modal that is not a repo operation's (those live on `RepoSession`); nil while closed.
    private(set) var modal: WindowModal?
    /// Closes the window; set by the AppDelegate. Called when the tab strip closes the last tab.
    @ObservationIgnored var closeWindow: () -> Void = {}
    /// The window; set by the AppDelegate. A tab switch moves its keyboard focus (`focusShownTab`).
    @ObservationIgnored weak var window: NSWindow?
    /// The terminal drawer's height in this window's tabs (dragged with its handle); each tab has its own terminal.
    var terminalHeight: CGFloat = TerminalDrawerMetrics.defaultHeight
    /// The operation toasts at the window's bottom right (`ToastHost`), oldest first. Read only by `ToastHost`.
    private(set) var toasts: [OperationToast] = []
    /// Each toast's timer, which closes it once its time is up. None while the pointer holds the toasts.
    @ObservationIgnored private var toastTimers: [OperationToast.ID: Task<Void, Never>] = [:]
    /// Each toast's time left, as of `toastStarts` (when its running timer started).
    @ObservationIgnored private var toastRemaining: [OperationToast.ID: Duration] = [:]
    @ObservationIgnored private var toastStarts: [OperationToast.ID: ContinuousClock.Instant] = [:]
    /// The pointer is over the toasts: their timers wait (`holdToasts`).
    @ObservationIgnored private var toastsHeld = false

    private static let logger = Logger(subsystem: "com.math2it.histq", category: "window")

    init() {
        selectedTabID = tabs.first?.id
        // `didSet` does not run in `init`: a repo opened in this first tab must be kept when another tab shows.
        recentlyShown = tabs.first.map { [$0.id] } ?? []
    }

    var selectedIndex: Int? { tabs.firstIndex { $0.id == selectedTabID } }

    /// The archived tab popped out beside the archive button, the last of `tabs`; nil when none is out.
    var archivedOut: Tab? { tabs.last?.archived == true ? tabs.last : nil }

    /// Where the normal tabs end in `tabs` (the popped-out archived tab comes after them): new tabs go here.
    private var normalEnd: Int { tabs.count - (archivedOut == nil ? 0 : 1) }

    // MARK: Toasts

    /// Shows an operation's outcome from the tab `tabID` when Settings' level shows its kind, naming the tab when it is
    /// not the one on screen. Its action first selects that tab, where it shows its dialog. Past `ToastHost.limit` the
    /// oldest closes, one without an action first. A toast with an action has no timer. `tabID` nil: the window's own
    /// toast (Settings), which names no tab.
    func showToast(_ toast: OperationToast, from tabID: Tab.ID? = nil) {
        guard ToastLevel.current.shows(toast.kind) else { return }
        var toast = toast
        guard let tabID else { return appendToast(toast) }
        if tabID != selectedTabID { toast.repo = tabs.first { $0.id == tabID }?.title }
        if let action = toast.action {
            toast.action = OperationToast.Action(title: action.title) { [weak self] in
                self?.selectTab(id: tabID)
                action.perform()
            }
        }
        appendToast(toast)
    }

    private func appendToast(_ toast: OperationToast) {
        #if DEBUG
        RepoMenus.debugLog("toast \(toast.title): \(toast.detail ?? "")")
        #endif
        toasts.append(toast)
        // A toast with an action stays until it is used or closed: the oldest toast without one goes first.
        while toasts.count > ToastHost.limit { dismissToast((toasts.first { $0.action == nil } ?? toasts[0]).id) }
        toastRemaining[toast.id] = toast.duration
        if !toastsHeld { startToastTimer(toast.id) }
    }

    /// Closes a toast (its x, its action, or its time is up).
    func dismissToast(_ id: OperationToast.ID) {
        toastTimers.removeValue(forKey: id)?.cancel()
        toastRemaining.removeValue(forKey: id)
        toastStarts.removeValue(forKey: id)
        toasts.removeAll { $0.id == id }
        // The last card went from under the pointer, which may never report leaving it.
        if toasts.isEmpty { toastsHeld = false }
    }

    /// The pointer entered (`true`) or left the toasts: their timers stop, keeping each one's time left, then start
    /// again from it, with at least a moment to see the toast once the pointer leaves.
    func holdToasts(_ held: Bool) {
        guard held != toastsHeld else { return }
        toastsHeld = held
        if held {
            let now = ContinuousClock.now
            for (id, timer) in toastTimers {
                timer.cancel()
                if let start = toastStarts[id], let remaining = toastRemaining[id] {
                    toastRemaining[id] = max(remaining - start.duration(to: now), .seconds(1.5))
                }
            }
            toastTimers.removeAll()
        } else {
            for toast in toasts { startToastTimer(toast.id) }
        }
    }

    /// Closes the toast `id` once its time left is up.
    private func startToastTimer(_ id: OperationToast.ID) {
        guard let remaining = toastRemaining[id] else { return }
        toastTimers[id]?.cancel()
        toastStarts[id] = .now
        toastTimers[id] = Task { [weak self] in
            try? await Task.sleep(for: remaining)
            guard !Task.isCancelled else { return }
            self?.dismissToast(id)
        }
    }

    /// The selected tab's session; nil for a Welcome tab.
    var selectedSession: RepoSession? { selectedTabID.flatMap { sessions[$0] } }

    /// A tab's profile, for its dot: its session's; for a restored tab not selected yet (no session), the one its
    /// session will start with: the saved one, else the repo's remembered one. nil for a Welcome or missing tab, no
    /// profile, or while the store is not read.
    func profile(of tab: Tab) -> Profile? {
        if let session = sessions[tab.id] { return session.profile }
        guard let url = tab.repoURL, !tab.isMissing, let store = ProfileLibrary.shared.store else { return nil }
        guard let saved = restored[tab.id]?.profile else { return store.profile(forRepo: url) }
        // As `RepoSession.profile`: a deleted profile falls back to the default.
        return saved.profileID.flatMap { store.profile(id: $0) ?? store.defaultProfile }
    }

    /// Switches a repo tab to a profile (nil: none), from the toolbar chip or the tab's right-click menu. A tab not
    /// selected yet has no session: its pick waits in `restored` until its session is made, without loading the repo.
    /// Either way the repo remembers it, as a pick in the chip does.
    func setProfile(_ profileID: UUID?, of id: Tab.ID) {
        if let session = sessions[id] { return session.setProfile(profileID) }
        guard let tab = tabs.first(where: { $0.id == id }), let url = tab.repoURL, !tab.isMissing else { return }
        var saved = restored[id] ?? SavedTab(path: url.path)
        saved.profile = SavedProfile(profileID)
        restored[id] = saved
        Task {
            let library = ProfileLibrary.shared
            guard await library.loaded() != nil else { return }
            library.update { $0.remember(profileID, forRepo: url) }
        }
    }

    /// The selected tab's session while the tab shows; nil for a
    /// Welcome tab. The toolbar's repo actions are disabled without it. Settings is a modal over the tab, so a
    /// toolbar action taken meanwhile opens its form or confirmation above the Settings modal.
    var actionSession: RepoSession? { navigation.page == .home ? selectedSession : nil }

    /// Opens a repo in a tab and selects it: the tab that already shows it, else the selected tab if it is a
    /// Welcome tab, else a new tab. `nil` opens a new Welcome tab. A worktree opened from the tab `opener` (a
    /// double-click in its sidebar, "Open in New Tab") joins the opener's group at once: its new tab goes right after
    /// the group's last tab, pinned when the group is (`gatherGroups`). Any other new tab goes last, and moves beside
    /// its repo's tabs once its repo is read (`resolveRepoKeys`). A repo in the archive pops out (`openArchived(at:)`)
    /// instead of opening twice.
    func openTab(_ url: URL?, opener: Tab.ID? = nil) {
        navigation.page = .home
        closeSettings()
        guard let url = url?.standardizedFileURL else {
            let tab = Tab()
            tabs.insert(tab, at: normalEnd)
            selectedTabID = tab.id
            return
        }
        UITiming.open(url.path)
        RecentRepos.shared.add(url)
        if let existing = tabs.firstIndex(where: { $0.repoURL?.path == url.path }) {
            // A "Repo not found" tab whose folder is opened again (it is back) opens it.
            if tabs[existing].isMissing {
                tabs[existing].isMissing = false
                resolveRepoKeys([tabs[existing].id])
            }
            selectedTabID = tabs[existing].id
        } else if let archived = archivedIndex(of: url.path) {
            return openArchived(at: archived)
        } else if let index = selectedIndex, tabs[index].repoURL == nil {
            tabs[index].repoURL = url
            resolveRepoKeys([tabs[index].id])
        } else if let opener = opener.flatMap({ id in tabs.firstIndex { $0.id == id } }) {
            var tab = Tab(repoURL: url)
            tab.repoKey = tabs[opener].repoKey
            tabs.insert(tab, at: min(groupEnd(of: opener) + 1, normalEnd))
            gatherGroups()
            selectedTabID = tab.id
            if tab.repoKey == nil { resolveRepoKeys([tab.id]) }
        } else {
            let tab = Tab(repoURL: url)
            tabs.insert(tab, at: normalEnd)
            selectedTabID = tab.id
            resolveRepoKeys([tab.id])
        }
        activateSelectedTab()
    }

    /// The Welcome tab `id`'s state, created on first use. Its Open, Clone and Init open the repo in that tab.
    func welcome(for id: Tab.ID) -> WelcomeModel {
        if let welcome = welcomes[id] { return welcome }
        let welcome = WelcomeModel { [weak self] url in self?.open(url, fromWelcome: id) }
        welcome.postToast = { [weak self] toast in self?.showToast(toast, from: id) }
        welcomes[id] = welcome
        return welcome
    }

    /// Opens a repo from the Welcome tab `id`: in that tab while it is selected (as `openTab`). A clone that ends
    /// after the user switched away fills that tab without selecting it, unless another tab or the archive has the
    /// repo.
    private func open(_ url: URL, fromWelcome id: Tab.ID) {
        welcomes.removeValue(forKey: id)
        guard selectedTabID != id else { return openTab(url) }
        let url = url.standardizedFileURL
        guard let index = tabs.firstIndex(where: { $0.id == id }), tabs[index].repoURL == nil,
              !tabs.contains(where: { $0.repoURL?.path == url.path }), archivedIndex(of: url.path) == nil
        else { return }
        UITiming.open(url.path)
        RecentRepos.shared.add(url)
        tabs[index].repoURL = url
        resolveRepoKeys([id])
    }

    /// Selects the tab at `index` and shows it (closing Settings): the path a click on a tab takes.
    /// The tab already selected is only shown again (its loaded detail stays); no `select` timing line then.
    func selectTab(at index: Int) {
        guard tabs.indices.contains(index) else { return }
        navigation.page = .home
        closeSettings()
        guard tabs[index].id != selectedTabID else { return }
        UITiming.select("tab \(index)")
        selectedTabID = tabs[index].id
        activateSelectedTab()
    }

    /// Shows the selected repo tab (creating its session on first use). A new session, or one whose detail is not
    /// loaded, selects its current selection again: its detail goes to the loading state now and reloads. A loaded
    /// detail stays as it is; the changes its watcher held while the tab was hidden are read as it shows
    /// (`RepoSession.isShown`), a held status with the WIP or the overview on its placeholder until read.
    private func activateSelectedTab() {
        guard let index = selectedIndex, let url = tabs[index].repoURL, !tabs[index].isMissing else { return }
        let id = tabs[index].id
        let isNew = sessions[id] == nil
        let session = sessions[id] ?? makeSession(for: id, url: url)
        sessions[id] = session
        if session.detail.value == nil { session.select(session.selection) }
        // Another worktree may have changed in its own tab meanwhile; a new session reads them after its first page.
        if !isNew { session.refreshWorktrees() }
    }

    /// After a tab switch (`TabContent`, in the view update's turn): the shown tab's view takes the keyboard, so no
    /// hidden tab's view keeps it (its arrows, Esc, ⌘Z and typing would act on a repo not shown). The open graph
    /// search, else panel 2's diff or blame, else the graph while panel 2 shows it, else nothing (the window). A target
    /// not in the window or not shown yet gets one main-queue hop, the window holding the focus meanwhile. Logs
    /// `focus <repo> <kind>` once.
    func focusShownTab(repo: String) {
        guard let window else { return }
        let targets = focusTargets()
        if let first = targets.first, take(first.view, in: window) { return UITiming.focus(repo, first.kind) }
        let resigned = window.makeFirstResponder(nil)
        guard !targets.isEmpty else { return UITiming.focus(repo, "none") }
        let id = selectedTabID
        DispatchQueue.main.async { [weak self, weak window] in
            // A newer switch moves the focus itself.
            guard let self, let window, selectedTabID == id else { return }
            // The old responder refused to resign: ask again before taking the target.
            if !resigned { window.makeFirstResponder(nil) }
            for target in focusTargets() where take(target.view, in: window) {
                return UITiming.focus(repo, target.kind)
            }
            UITiming.focus(repo, "none")
        }
    }

    /// The shown tab's focus targets, best first, from what it shows (a tool stays mounted under the diff opened from
    /// it, so a live view alone says nothing). The graph only while panel 2 shows it, not under a file, a pull
    /// request or a tool. None under the tab's own modal (one opened while it was hidden), which takes the keyboard.
    private func focusTargets() -> [(kind: String, view: NSView?)] {
        guard let session = selectedSession, !session.hasModal else { return [] }
        let showsGraph = session.openFile == nil && session.openHosted == nil && session.openTool == nil
        var targets: [(kind: String, view: NSView?)] = []
        if showsGraph, session.graphSearch.isOpen { targets.append(("search", session.graphSearch.field)) }
        if let file = session.openFile, !file.isConflict { targets.append(("diff", session.diffTable)) }
        if session.openFile == nil, case .blame? = session.openTool { targets.append(("blame", session.blameTable)) }
        if showsGraph, session.log.value != nil { targets.append(("graph", session.graphSearch.table)) }
        return targets
    }

    /// Gives `view` the keyboard when it is in `window` and shown; false when it is not (yet), or refuses.
    private func take(_ view: NSView?, in window: NSWindow) -> Bool {
        guard let view, view.window === window, !view.isHiddenOrHasHiddenAncestor else { return false }
        return window.firstResponder === view || window.makeFirstResponder(view)
    }

    /// A tab's session, with the profile a restored tab had in the saved session. Its graph opens on the WIP or HEAD,
    /// as a new tab does.
    private func makeSession(for id: Tab.ID, url: URL) -> RepoSession {
        let session = RepoSession(url: url)
        // A worktree's "Open in New Tab" and a double-click on its sidebar row open it in this window, beside this
        // tab's group. The worktree's tab shows its changes, else its HEAD commit, even when it was open on another
        // row.
        session.openInTab = { [weak self] url in
            self?.openTab(url, opener: id)
            self?.selectedSession?.showWorkingState()
        }
        // A submodule's "Open in New Tab" opens its own repo: a tab outside this tab's group.
        session.openRepoInTab = { [weak self] url in self?.openTab(url) }
        session.postToast = { [weak self] toast in self?.showToast(toast, from: id) }
        session.worktreeRemoved = { [weak self] path in self?.closeRemovedWorktreeTabs(path) }
        let saved = restored.removeValue(forKey: id)
        if let profile = saved?.profile { session.restoreProfile(profile.profileID) }
        // Settings › Terminal "Open terminal with each new tab": a repo the user opens now (Open, a recent repo, a clone
        // or init filling a Welcome tab, a restored Welcome tab too), not a restored repo tab. Only the drawer: its
        // shell starts when the user clicks into it (`showTerminalDrawer`).
        if saved?.path == nil, Preferences.defaults.bool(forKey: PrefKey.terminalOpenWithNewTab.rawValue) {
            session.showTerminalDrawer()
        }
        #if DEBUG
        if AppState.launchFlag("-HistqTerminalProbe") == url.lastPathComponent, !Self.terminalProbeStarted {
            Self.terminalProbeStarted = true
            Task { [weak self] in await self?.runTerminalProbe(session, tabID: id) }
        }
        if let spec = AppState.launchFlag("-HistqTerminalSettingsProbe"), !Self.terminalProbeStarted {
            Self.terminalProbeStarted = true
            Task { [weak self] in await self?.runTerminalSettingsProbe(spec, session: session) }
        }
        #endif
        return session
    }

    /// The toolbar's Terminal button and View › Show Terminal (⌃`): the selected repo tab's drawer.
    func toggleTerminal() {
        actionSession?.toggleTerminal()
    }

    #if DEBUG
    private static var terminalProbeStarted = false

    /// DEBUG `-HistqTerminalProbe <repo folder name>` (QA of the terminal where no screenshot can be taken, on fixture
    /// copies): opens that repo's terminal (its first session) and logs the shell's pid and its first screen (the
    /// prompt) to `operations.txt`; types one line that writes what the shell sees (`git var GIT_AUTHOR_IDENT`, the
    /// count of `HISTQ_GIT_TOKEN` and credential variables, its `GIT_CONFIG_*` list) to `terminal-probe.txt` in the
    /// state dir; then closes the tab as ⌘W does and logs whether the pid is gone (`kill(pid, 0)`).
    private func runTerminalProbe(_ session: RepoSession, tabID: Tab.ID) async {
        session.openTerminal()
        var pid: pid_t = 0
        for _ in 0..<100 {
            pid = session.terminal?.shellPid ?? 0
            if pid > 0 { break }
            try? await Task.sleep(for: .milliseconds(50))
        }
        guard pid > 0, let terminal = session.terminal else { return RepoMenus.debugLog("terminal: no shell started") }
        RepoMenus.debugLog("terminal pid \(pid) shell \(RepoTerminal.loginShell())")
        // The prompt: the screen once the shell has drawn something and been quiet for a moment.
        for _ in 0..<100 {
            if !terminal.screenLines().isEmpty { break }
            try? await Task.sleep(for: .milliseconds(50))
        }
        try? await Task.sleep(for: .milliseconds(800))
        for line in terminal.screenLines().prefix(6) { RepoMenus.debugLog("terminal prompt: \(line)") }
        let output = StatePaths.root.appending(path: "terminal-probe.txt").path
        let partial = output + ".part"
        terminal.type("{ git var GIT_AUTHOR_IDENT; echo token=$(env | grep -c HISTQ_GIT_TOKEN); "
            + "echo credential=$(env | grep -ci credential); env | grep '^GIT_CONFIG_' | sort; echo pwd=$(pwd); } "
            + "> '\(partial)' 2>&1; mv '\(partial)' '\(output)'\r")
        for _ in 0..<200 {
            if FileManager.default.fileExists(atPath: output) { break }
            try? await Task.sleep(for: .milliseconds(50))
        }
        try? await Task.sleep(for: .milliseconds(300))
        for line in terminal.screenLines().suffix(3) { RepoMenus.debugLog("terminal screen: \(line)") }
        RepoMenus.debugLog("terminal close tab")
        if !closeTab(id: tabID) { closeWindow() }
        let start = ContinuousClock.now
        for _ in 0..<60 {
            if kill(pid, 0) == -1, errno == ESRCH { break }
            try? await Task.sleep(for: .milliseconds(50))
        }
        let gone = kill(pid, 0) == -1 && errno == ESRCH
        RepoMenus.debugLog("terminal pid \(pid) after close: \(gone ? "gone" : "alive") "
            + "(\(Int((ContinuousClock.now - start) / .milliseconds(1))) ms)")
    }

    /// DEBUG `-HistqTerminalSettingsProbe <spec>` (QA of Settings › Terminal; the app's first session). Writes the
    /// preferences as the Settings page does, so the production observers apply them, and logs to `operations.txt`:
    /// - `live` (with `-HistqOpenTerminal YES`): the open terminal's font, cursor and scrollback, read from the view,
    ///   before, after setting Menlo 16 / bar / 1000, and after removing the keys again.
    /// - `newtab:<repo a>,<repo b>`: opens `a` with "Open terminal with each new tab" off (control), then `b` with it
    ///   on, logging whether each new tab's drawer opened and its shell started (5 s for an open drawer: it must stay
    ///   "none" until the click); then clicks the pending drawer as its placeholder does and logs the shell's pid;
    ///   removes the key.
    private func runTerminalSettingsProbe(_ spec: String, session: RepoSession) async {
        let defaults = Preferences.defaults
        if spec == "live" {
            var pid: pid_t = 0
            for _ in 0..<100 {
                pid = session.terminal?.shellPid ?? 0
                if pid > 0 { break }
                try? await Task.sleep(for: .milliseconds(50))
            }
            guard pid > 0, let terminal = session.terminal else {
                return RepoMenus.debugLog("terminal settings: no shell started")
            }
            // The drawer's layout settles first, so the column counts compare at one width.
            try? await Task.sleep(for: .milliseconds(500))
            RepoMenus.debugLog("terminal settings before: \(terminal.appearanceDescription())")
            let keys: [PrefKey] = [.terminalFontName, .terminalFontSize, .terminalCursor, .terminalScrollback]
            defaults.set("Menlo-Regular", forKey: PrefKey.terminalFontName.rawValue)
            defaults.set(16.0, forKey: PrefKey.terminalFontSize.rawValue)
            defaults.set("bar", forKey: PrefKey.terminalCursor.rawValue)
            defaults.set(1000, forKey: PrefKey.terminalScrollback.rawValue)
            try? await Task.sleep(for: .milliseconds(300))
            RepoMenus.debugLog("terminal settings after set: \(terminal.appearanceDescription())")
            for key in keys { defaults.removeObject(forKey: key.rawValue) }
            try? await Task.sleep(for: .milliseconds(300))
            RepoMenus.debugLog("terminal settings after remove: \(terminal.appearanceDescription())")
        } else if spec.hasPrefix("newtab:") {
            let paths = spec.dropFirst("newtab:".count).split(separator: ",").map(String.init)
            guard paths.count == 2 else { return RepoMenus.debugLog("terminal settings: newtab needs two repos") }
            let key = PrefKey.terminalOpenWithNewTab.rawValue
            for (path, on) in zip(paths, [false, true]) {
                if on { defaults.set(true, forKey: key) } else { defaults.removeObject(forKey: key) }
                openTab(URL(fileURLWithPath: path, isDirectory: true))
                guard let opened = selectedSession else { continue }
                let drawer = opened.isTerminalOpen
                var pid: pid_t = 0
                for _ in 0..<(drawer ? 100 : 10) {
                    pid = opened.terminal?.shellPid ?? 0
                    if pid > 0 { break }
                    try? await Task.sleep(for: .milliseconds(50))
                }
                RepoMenus.debugLog("terminal new tab \(opened.url.lastPathComponent) pref \(on ? "on" : "off"): "
                    + "drawer \(drawer ? "open" : "closed") shell \(pid > 0 ? "pid \(pid)" : "none") "
                    + "terminal \(opened.terminal == nil ? "none" : "made") pending \(opened.isTerminalPending)")
                // The placeholder's click: only now does the shell start.
                guard opened.isTerminalPending else { continue }
                opened.openTerminal()
                for _ in 0..<100 {
                    pid = opened.terminal?.shellPid ?? 0
                    if pid > 0 { break }
                    try? await Task.sleep(for: .milliseconds(50))
                }
                RepoMenus.debugLog("terminal new tab \(opened.url.lastPathComponent) after click: "
                    + "shell \(pid > 0 ? "pid \(pid)" : "none") pending \(opened.isTerminalPending)")
            }
            defaults.removeObject(forKey: key)
        }
    }

    /// DEBUG `-HistqTabWalk <rounds>[,<ms>]` (timing of tab switches; started once per launch by the app): once the
    /// open sessions' logs are complete, selects each tab in turn through `selectTab(at:)`, the click path, `ms` apart
    /// (default 1500), `rounds` times (the first visits create the sessions). After the rounds it selects tab 0, logs
    /// `walk tail` (the harness changes tab 2's repo now), waits 3 s, selects tab 1 and then tab 2 once more, and logs
    /// `walk done`. Each switch logs a `tab-frame` line (`tabWalkSelect`).
    func runTabWalk(_ spec: String) async {
        let parts = spec.split(separator: ",").map { Int($0.trimmingCharacters(in: .whitespaces)) }
        guard let rounds = parts.first ?? nil, rounds > 0 else {
            return Self.logger.error("-HistqTabWalk: expected <rounds>[,<ms>], got \(spec, privacy: .public)")
        }
        let interval = (parts.count > 1 ? parts[1] : nil) ?? 1500
        for _ in 0..<600 {
            if !sessions.isEmpty, sessions.values.allSatisfy({ $0.log.value?.isComplete == true }) { break }
            try? await Task.sleep(for: .milliseconds(100))
        }
        // Lets the launch's last frames go by, so the first switch is not timed against them.
        try? await Task.sleep(for: .milliseconds(500))
        UITiming.walk("start tabs \(tabs.count) rounds \(rounds) every \(interval) ms")
        for round in 1...rounds {
            UITiming.walk("round \(round)")
            for index in tabs.indices where tabs[index].id != selectedTabID {
                await tabWalkSelect(index, interval: interval)
            }
        }
        await tabWalkSelect(0, interval: 0)
        UITiming.walk("tail")
        try? await Task.sleep(for: .seconds(3))
        await tabWalkSelect(1, interval: interval)
        await tabWalkSelect(2, interval: 0)
        UITiming.walk("done")
    }

    /// Selects tab `index` as a click does, then ticks every 5 ms on the main actor for 500 ms and logs `tab-frame
    /// <index> max=<ms> over16=<ms>`: the largest gap between two ticks (from just before the select) and the sum of
    /// the gaps longer than 16 ms (the main thread's holds, the switch's later runloop turns included). Then waits
    /// until `interval` ms after the select.
    private func tabWalkSelect(_ index: Int, interval: Int) async {
        let start = ContinuousClock.now
        var last = start
        var longest = Duration.zero
        var over16 = Duration.zero
        selectTab(at: index)
        while last - start < .milliseconds(500) {
            try? await Task.sleep(for: .milliseconds(5))
            let now = ContinuousClock.now
            let gap = now - last
            longest = max(longest, gap)
            if gap > .milliseconds(16) { over16 += gap }
            last = now
        }
        let ms: (Duration) -> String = { String(format: "%.1f", Double($0 / .microseconds(1)) / 1000) }
        UITiming.tabFrame("\(index) max=\(ms(longest)) over16=\(ms(over16))")
        try? await Task.sleep(for: .milliseconds(interval) - (ContinuousClock.now - start))
    }
    #endif

    // MARK: Session restore

    /// Session restore: this new window's tabs become `saved` (`missing` = the folders that are gone) and the saved
    /// selected tab opens, as a click would show it. Not `openTab`: no recent-repos update, and the other tabs get their
    /// session only when selected. The archived entries go back to the archive, but the selected one: it is popped
    /// out again, last and selected.
    func restore(_ saved: [SavedTab], selected: Int?, missing: Set<String>) {
        guard !saved.isEmpty else { return }
        welcomes.removeAll()
        var entries: [SavedTab] = []
        var popped: SavedTab?
        var selectedEntry: Int?
        archivedTabs = []
        for (offset, entry) in saved.enumerated() {
            if entry.archived != true {
                if offset == selected { selectedEntry = entries.count }
                entries.append(entry)
            } else if entry.path != nil {
                if offset == selected { popped = entry } else { archivedTabs.append(entry) }
            }
        }
        if let popped {
            selectedEntry = entries.count
            entries.append(popped)
        }
        tabs = entries.map { tab in
            let archived = tab.archived == true
            return Tab(repoURL: tab.path.map { URL(fileURLWithPath: $0, isDirectory: true) },
                       isMissing: tab.path.map(missing.contains) ?? false, alias: tab.alias, emoji: tab.emoji,
                       pinned: archived ? false : tab.pinned ?? false, iconColor: tab.iconColor, archived: archived)
        }
        restored = Dictionary(uniqueKeysWithValues: zip(tabs.map(\.id), entries))
        if tabs.isEmpty { tabs = [Tab()] }
        resolveRepoKeys(tabs.filter { !$0.isMissing && !$0.archived }.map(\.id))
        let index = selectedEntry ?? 0
        selectedTabID = tabs[index].id
        if let url = tabs[index].repoURL, !tabs[index].isMissing { UITiming.open(url.path) }
        activateSelectedTab()
    }

    /// The tabs as the session saves them, in order. A tab with a session saves its live profile and commit; one
    /// without keeps what it was restored with. Observable: reading it in `withObservationTracking` follows every
    /// change it depends on (tabs, their sessions' selection and profile, the archive). The stowed archived tabs come
    /// after every tab, so the normal tabs keep their indices.
    var savedTabs: [SavedTab] {
        tabs.map(saved) + archivedTabs
    }

    /// One tab as the session saves it (`savedTabs`), and as ⇧⌘T reopens it.
    private func saved(_ tab: Tab) -> SavedTab {
        let path = tab.repoURL?.path
        guard let session = sessions[tab.id] else {
            var saved = restored[tab.id] ?? SavedTab()
            saved.path = path
            saved.alias = tab.alias
            saved.emoji = tab.emoji
            saved.pinned = tab.pinned ? true : nil
            saved.iconColor = tab.iconColor
            saved.archived = tab.archived ? true : nil
            return saved
        }
        // Before the repo's profile is resolved, its id says nothing yet: a later launch resolves it again.
        let profile = session.profileResolved ? SavedProfile(session.profileID) : nil
        return SavedTab(path: path, profile: profile, alias: tab.alias, emoji: tab.emoji,
                        pinned: tab.pinned ? true : nil, iconColor: tab.iconColor, archived: tab.archived ? true : nil)
    }

    /// "Repo not found" › Locate: the tab opens `url` instead (the tab that already shows it when there is one, or
    /// its entry in the archive, popped out).
    func locate(_ id: Tab.ID, at url: URL) {
        let url = url.standardizedFileURL
        guard let index = tabs.firstIndex(where: { $0.id == id }) else { return }
        if let existing = tabs.first(where: { $0.id != id && $0.repoURL?.path == url.path }) {
            _ = closeTab(id: id)
            return selectTab(id: existing.id)
        }
        if archivedIndex(of: url.path) != nil {
            // Removed directly, not through `closeTab`: a lone tab must not give way to a Welcome tab first. A
            // popped-out tab is stowed at the archive's front, so the entry is looked up again after.
            remove(at: index)
            if let archived = archivedIndex(of: url.path) { openArchived(at: archived) }
            return
        }
        UITiming.open(url.path)
        RecentRepos.shared.add(url)
        tabs[index].repoURL = url
        tabs[index].isMissing = false
        tabs[index].repoKey = nil
        resolveRepoKeys([id])
        if selectedTabID == id { activateSelectedTab() }
    }

    /// Selects a tab by id, through `selectTab(at:)`.
    func selectTab(id: Tab.ID) {
        guard let index = tabs.firstIndex(where: { $0.id == id }) else { return }
        selectTab(at: index)
    }

    /// Closes the selected tab and selects its neighbor. Returns false when no tab is left (the window closes).
    func closeSelectedTab() -> Bool {
        guard let id = selectedTabID else { return !tabs.isEmpty }
        return closeTab(id: id)
    }

    /// Closes a tab; when it was the selected one, its neighbor is selected. Returns false when no tab is left (the
    /// caller closes the window). The popped-out archived tab goes back to the archive. A window whose archive is not
    /// empty does not close when its last repo tab closes: a Welcome tab takes its place, so the archive stays
    /// reachable. Closing that lone Welcome tab closes the window.
    func closeTab(id: Tab.ID) -> Bool {
        closeTab(id: id, archiving: false)
    }

    /// `closeTab(id:)`, or with `archiving` the tab goes to the archive instead of the stack ⇧⌘T reopens.
    private func closeTab(id: Tab.ID, archiving: Bool) -> Bool {
        guard let index = tabs.firstIndex(where: { $0.id == id }) else { return !tabs.isEmpty }
        let wasWelcome = tabs[index].repoURL == nil
        remove(at: index, archiving: archiving)
        // A lone Welcome tab still closes the window (⌘W), its archive with it.
        if tabs.isEmpty, !archivedTabs.isEmpty, !wasWelcome {
            let welcome = Tab()
            tabs = [welcome]
            selectedTabID = welcome.id
            return true
        }
        if selectedTabID == id {
            // The next shown normal tab, else the one before: a collapsed group stays collapsed unless nothing else is
            // left. The popped-out archived tab only when no normal tab is left.
            let next = min(index, normalEnd - 1)
            let shown = (0..<normalEnd).filter { !isHidden($0) }
            let fallback = normalEnd > 0 ? next : tabs.count - 1
            selectedTabID = tabs.isEmpty ? nil : tabs[shown.first { $0 >= next } ?? shown.last ?? fallback].id
            activateSelectedTab()
        }
        return !tabs.isEmpty
    }

    /// A tab's menu › Close Other Tabs: every tab but `id`, which is selected. The popped-out archived tab stays.
    func closeOtherTabs(_ id: Tab.ID) {
        let popped = archivedOut?.id
        closeTabs(keeping: id) { $0 != id && $0 != popped }
    }

    /// A tab's menu › Close Tabs to the Right (Below, in the vertical tabs): the tabs after `id`; `id` is selected when
    /// the selected tab was one of them. The popped-out archived tab stays.
    func closeTabs(after id: Tab.ID) {
        guard let index = tabs.firstIndex(where: { $0.id == id }) else { return }
        let after = Set(tabs[(index + 1)...].filter { !$0.archived }.map(\.id))
        closeTabs(keeping: id) { after.contains($0) }
    }

    /// Closes the tabs `closes` picks, left to right (so ⇧⌘T, last closed first, puts each back at its index). The
    /// selection moves to `keeping` once, first, when the selected tab is closed: no tab in between gets a session.
    private func closeTabs(keeping: Tab.ID, where closes: (Tab.ID) -> Bool) {
        if let selectedTabID, closes(selectedTabID) { selectTab(id: keeping) }
        while let index = tabs.firstIndex(where: { closes($0.id) }) {
            remove(at: index)
        }
    }

    /// A worktree removed from another tab (its sidebar or graph menu): its tabs in this window close, and ⇧⌘T forgets
    /// them, as its folder is gone, and so does the archive (a popped-out tab of that worktree included). The window's
    /// last tab stays (it shows "Repo not found").
    private func closeRemovedWorktreeTabs(_ path: String) {
        // The folder is gone: its parent's symlinks are resolved (git's `/private/tmp/…` is a tab's `/tmp/…`).
        func key(_ url: URL) -> String {
            let url = url.standardizedFileURL
            return url.deletingLastPathComponent().resolvingSymlinksInPath().appending(path: url.lastPathComponent).path
        }
        let removed = key(URL(filePath: path, directoryHint: .isDirectory))
        for tab in tabs where tab.repoURL.map(key) == removed && tabs.count > 1 {
            _ = closeTab(id: tab.id)
        }
        // After the loop: a popped-out tab of that worktree was just stowed, and the archive forgets it too.
        archivedTabs.removeAll { $0.path.map { key(URL(filePath: $0)) } == removed }
        closedTabs.removeAll { $0.saved.path.map { key(URL(filePath: $0)) } == removed }
    }

    /// Removes the tab at `index` with its session and state; a repo tab goes on the stack ⇧⌘T reopens. The
    /// popped-out archived tab, or any tab when `archiving`, goes to the archive's front instead (unpinned).
    private func remove(at index: Int, archiving: Bool = false) {
        let tab = tabs[index]
        if tab.archived || archiving {
            var entry = saved(tab)
            entry.archived = true
            entry.pinned = nil
            archivedTabs.insert(entry, at: 0)
        } else if tab.repoURL != nil, !tab.isMissing {
            closedTabs.append(ClosedTab(saved: saved(tab), repoKey: tab.repoKey, index: index))
            if closedTabs.count > Self.closedTabsLimit { closedTabs.removeFirst() }
        }
        tabs.remove(at: index)
        // A group left with one tab is no group: it must not come back collapsed.
        if let key = tab.repoKey, collapsedGroups.contains(key), !tabGroups.contains(where: { $0.key == key }) {
            collapsedGroups.remove(key)
        }
        restored.removeValue(forKey: tab.id)
        sessions.removeValue(forKey: tab.id)?.close()
        recentlyShown.removeAll { $0 == tab.id }
        welcomes.removeValue(forKey: tab.id)?.cancel()
    }

    /// A tab was closed in this window that ⇧⌘T can reopen.
    var canReopenClosedTab: Bool { !closedTabs.isEmpty }

    /// ⇧⌘T: reopens the last closed repo tab at its index, back in its worktree group (`gatherGroups`), with its
    /// profile, commit, alias, emoji and pin, and selects it. A repo open again in another tab meanwhile is selected
    /// instead, and one in the archive pops out.
    func reopenClosedTab() {
        guard let closed = closedTabs.popLast(), let path = closed.saved.path else { return }
        navigation.page = .home
        closeSettings()
        if let existing = tabs.first(where: { $0.repoURL?.path == path }) { return selectTab(id: existing.id) }
        if let archived = archivedIndex(of: path) { return openArchived(at: archived) }
        let url = URL(fileURLWithPath: path, isDirectory: true)
        var isDirectory: ObjCBool = false
        let exists = FileManager.default.fileExists(atPath: path, isDirectory: &isDirectory) && isDirectory.boolValue
        var tab = Tab(repoURL: url, isMissing: !exists, alias: closed.saved.alias, emoji: closed.saved.emoji,
                      pinned: closed.saved.pinned ?? false, iconColor: closed.saved.iconColor, archived: false)
        tab.repoKey = closed.repoKey
        tabs.insert(tab, at: min(closed.index, normalEnd))
        restored[tab.id] = closed.saved
        gatherGroups()
        if exists, tab.repoKey == nil { resolveRepoKeys([tab.id]) }
        UITiming.select("reopen tab")
        selectedTabID = tab.id
        activateSelectedTab()
    }

    // MARK: Archive

    /// A repo tab's menu › Archive This Tab: the tab goes to the archive's front (its profile, commit, alias, emoji
    /// and icon color kept), its session closes, and its neighbor is selected as when it closes; ⇧⌘T does not reopen
    /// it. On the popped-out archived tab it is the same as closing it. The window never closes: its last tab gives way
    /// to a Welcome tab.
    func archiveTab(_ id: Tab.ID) {
        guard let tab = tabs.first(where: { $0.id == id }), tab.repoURL != nil else { return }
        _ = closeTab(id: id, archiving: true)
    }

    /// A click on the archive's row `index`: that tab pops out, last in `tabs`, selected and shown as ⇧⌘T shows a
    /// tab (a new session with its saved profile and commit). The tab popped out before goes back to the archive's
    /// front. The popped tab never joins a group, so its repo is not read.
    func openArchived(at index: Int) {
        guard archivedTabs.indices.contains(index), let path = archivedTabs[index].path else { return }
        // The entry first, then the tab popped out before: stowing it shifts the archive's indices.
        let entry = archivedTabs.remove(at: index)
        navigation.page = .home
        closeSettings()
        if archivedOut != nil { remove(at: tabs.count - 1) }
        let url = URL(fileURLWithPath: path, isDirectory: true)
        var isDirectory: ObjCBool = false
        let exists = FileManager.default.fileExists(atPath: path, isDirectory: &isDirectory) && isDirectory.boolValue
        let tab = Tab(repoURL: url, isMissing: !exists, alias: entry.alias, emoji: entry.emoji, pinned: false,
                      iconColor: entry.iconColor, archived: true)
        // The popped-out tab is always the last one.
        tabs.append(tab)
        restored[tab.id] = entry
        UITiming.select("archived tab")
        selectedTabID = tab.id
        activateSelectedTab()
    }

    /// The popped-out tab's menu › Unarchive Tab: it becomes a normal tab at the start of the unpinned area, then
    /// rejoins its worktree group once its repo is read. The selection stays.
    func unarchiveTab(_ id: Tab.ID) {
        guard let index = tabs.firstIndex(where: { $0.id == id }), tabs[index].archived else { return }
        var tab = tabs.remove(at: index)
        tab.archived = false
        tabs.insert(tab, at: pinnedCount)
        if !tab.isMissing { resolveRepoKeys([id]) }
    }

    /// The × on the archive's row `index`: the entry leaves the archive, and ⇧⌘T can reopen it as a normal tab.
    func removeArchived(at index: Int) {
        guard archivedTabs.indices.contains(index) else { return }
        var entry = archivedTabs.remove(at: index)
        entry.archived = nil
        guard entry.path != nil else { return }
        closedTabs.append(ClosedTab(saved: entry, repoKey: nil, index: normalEnd))
        if closedTabs.count > Self.closedTabsLimit { closedTabs.removeFirst() }
    }

    /// The index in `archivedTabs` of the entry for the repo folder `path`; nil when the archive has none.
    private func archivedIndex(of path: String) -> Int? {
        archivedTabs.firstIndex { $0.path == path }
    }

    /// A tab's menu › Set Alias…: `alias` names the tab; empty (or only spaces) gives it back its folder's name.
    func setAlias(_ alias: String, for id: Tab.ID) {
        guard let index = tabs.firstIndex(where: { $0.id == id }) else { return }
        let trimmed = alias.trimmingCharacters(in: .whitespacesAndNewlines)
        tabs[index].alias = trimmed.isEmpty ? nil : trimmed
    }

    /// A tab's menu › Set Emoji…: `emoji` marks the tab, its last emoji only (`TabEmoji.normalized`); nil, or text
    /// with no emoji, removes it.
    func setEmoji(_ emoji: String?, for id: Tab.ID) {
        guard let index = tabs.firstIndex(where: { $0.id == id }) else { return }
        tabs[index].emoji = emoji.flatMap(TabEmoji.normalized)
    }

    /// A tab's menu › Icon Color: the book icon's color, an index into `Palette.graphLanes`; nil for the default.
    func setIconColor(_ color: Int?, for id: Tab.ID) {
        guard let index = tabs.firstIndex(where: { $0.id == id }) else { return }
        tabs[index].iconColor = color
    }

    /// A tab's menu › Pin Tab / Unpin Tab: pins or unpins the tab, with its whole worktree group (the tabs of its
    /// `repoKey`). Pinned tabs go to the end of the pinned area, unpinned ones to the start of the other tabs. The
    /// selection stays.
    func setPinned(_ pinned: Bool, for id: Tab.ID) {
        // The popped-out archived tab is never pinned.
        guard let tab = tabs.first(where: { $0.id == id }), !tab.archived else { return }
        let isAffected: (Tab) -> Bool = { other in tab.repoKey.map { other.repoKey == $0 } ?? (other.id == id) }
        guard tabs.contains(where: { isAffected($0) && $0.pinned != pinned }) else { return }
        var moved = tabs.filter(isAffected)
        let rest = tabs.filter { !isAffected($0) }
        for index in moved.indices { moved[index].pinned = pinned }
        let boundary = rest.prefix { $0.pinned }.count
        tabs = Array(rest[..<boundary]) + moved + Array(rest[boundary...])
        gatherGroups()
    }

    /// The number of pinned tabs, which come first in `tabs`.
    var pinnedCount: Int { tabs.prefix { $0.pinned }.count }


    /// Moves the tab at `source` to `destination` (its index once moved), one of `moveDestinations(from:)`; the
    /// selection stays on the same tab.
    func moveTab(from source: Int, to destination: Int) {
        guard tabs.indices.contains(source), source != destination,
              moveDestinations(from: source).contains(destination)
        else { return }
        let tab = tabs.remove(at: source)
        tabs.insert(tab, at: destination)
    }

    // MARK: Tab groups

    /// The runs of two or more neighboring tabs of one repository, in tab order. The popped-out archived tab is in
    /// none.
    var tabGroups: [TabGroup] {
        var groups: [TabGroup] = []
        var start = 0
        while start < tabs.count {
            var end = start
            if let key = tabs[start].repoKey, !tabs[start].archived {
                while end + 1 < tabs.count, tabs[end + 1].repoKey == key, !tabs[end + 1].archived { end += 1 }
                if end > start {
                    groups.append(TabGroup(key: key, range: start...end, name: TabGroupNames.shared.name(of: key)))
                }
            }
            start = end + 1
        }
        return groups
    }

    /// Where the tab at `source` may be dropped (indices once moved): a grouped tab only within its group, another
    /// tab anywhere but between two tabs of a group, so a group is never split; and a pinned tab only among the pinned
    /// tabs, an unpinned one only among the others (before the popped-out archived tab, which never moves).
    func moveDestinations(from source: Int) -> [Int] {
        guard tabs.indices.contains(source), !tabs[source].archived else { return [] }
        if let group = tabGroups.first(where: { $0.range.contains(source) }) { return Array(group.range) }
        let area = tabs[source].pinned ? 0..<pinnedCount : pinnedCount..<normalEnd
        var rest = tabs.map(\.repoKey)
        rest.remove(at: source)
        return (0...rest.count).filter { index in
            area.contains(index)
                && (index == 0 || index == rest.count || rest[index] == nil || rest[index - 1] != rest[index])
        }
    }

    /// A click on a group's name: collapses it to its name, or shows its tabs again. Collapsing the selected tab's
    /// group selects the next shown tab after it, else before it, else the popped-out archived tab, else a new tab.
    func toggleGroup(_ key: String) {
        if collapsedGroups.contains(key) {
            collapsedGroups.remove(key)
            return
        }
        guard let group = tabGroups.first(where: { $0.key == key }) else { return }
        if let selected = selectedIndex, group.range.contains(selected) {
            let shown = (0..<normalEnd).filter { !group.range.contains($0) && !isHidden($0) }
            let popped = archivedOut == nil ? nil : tabs.count - 1
            if let next = shown.first(where: { $0 > group.range.upperBound }) ?? shown.last ?? popped {
                selectTab(at: next)
            } else {
                openTab(nil)
            }
        }
        collapsedGroups.insert(key)
    }

    /// The tab at `index` is in a collapsed group.
    private func isHidden(_ index: Int) -> Bool {
        tabs[index].repoKey.map(collapsedGroups.contains) ?? false
    }

    /// Opens the selected tab's group when it is collapsed (checked first, so a selection does not touch the set).
    private func expandSelectedGroup() {
        guard let key = selectedIndex.flatMap({ tabs[$0].repoKey }), collapsedGroups.contains(key) else { return }
        collapsedGroups.remove(key)
    }

    /// The last index of the group the tab at `index` is in; `index` itself when it is in none.
    private func groupEnd(of index: Int) -> Int {
        guard let key = tabs[index].repoKey else { return index }
        var end = index
        while end + 1 < tabs.count, tabs[end + 1].repoKey == key { end += 1 }
        return end
    }

    /// Reads the repositories of the tabs `ids` off the main thread, then sets their `repoKey` and gathers each
    /// repo's tabs side by side.
    private func resolveRepoKeys(_ ids: [Tab.ID]) {
        let targets = ids.compactMap { id in tabs.first { $0.id == id }?.repoURL.map { (id, $0) } }
        guard !targets.isEmpty else { return }
        Task { [weak self] in
            let keys = await Task.detached { targets.map { ($0.0, $0.1, RepoGroupKey.of($0.1)) } }.value
            self?.applyRepoKeys(keys)
        }
    }

    private func applyRepoKeys(_ keys: [(Tab.ID, URL, String?)]) {
        // A tab closed or pointed elsewhere (Locate) meanwhile keeps what it has. The popped-out archived tab never
        // joins a group.
        for (id, url, key) in keys {
            guard let index = tabs.firstIndex(where: { $0.id == id }), tabs[index].repoURL == url,
                  !tabs[index].archived, tabs[index].repoKey != key
            else { continue }
            tabs[index].repoKey = key
        }
        gatherGroups()
    }

    /// Moves each repo's tabs right after its first tab, the others keeping their order; then pins a whole group when
    /// one of its tabs is pinned and moves the pinned tabs first, each side
    /// keeping its order. The popped-out archived tab is left out of both and stays last. The selection stays.
    private func gatherGroups() {
        var gathered: [Tab] = []
        var placed = Set<String>()
        for tab in tabs where !tab.archived {
            guard let key = tab.repoKey else {
                gathered.append(tab)
                continue
            }
            guard placed.insert(key).inserted else { continue }
            gathered += tabs.filter { $0.repoKey == key && !$0.archived }
        }
        // A tab that joins a pinned group (a new worktree tab, a repo read, Locate, ⇧⌘T) is pinned with it.
        let pinnedKeys = Set(gathered.filter(\.pinned).compactMap(\.repoKey))
        for index in gathered.indices where !gathered[index].pinned {
            if let key = gathered[index].repoKey, pinnedKeys.contains(key) { gathered[index].pinned = true }
        }
        // Groups stay side by side: each is wholly pinned or not.
        gathered = gathered.filter(\.pinned) + gathered.filter { !$0.pinned } + tabs.filter(\.archived)
        if gathered != tabs { tabs = gathered }
        // The selected tab may just have joined a collapsed group (a Welcome tab's repo read).
        expandSelectedGroup()
    }

    /// The toolbar's Settings button: opens the Settings modal, or closes it when it shows.
    func toggleSettings() {
        if isSettingsOpen { closeSettings() } else { openSettings() }
    }

    /// Opens the Settings modal at its last section (⌘,), over the page as it is. Whatever was open over the page
    /// closes first, as the page switch did before 9.7: the palette, a window modal, the tab's form or confirmation.
    func openSettings() {
        guard !isSettingsOpen else { return }
        palette = nil
        modal = nil
        if let session = selectedSession, session.hasModal { session.closeModals() }
        isSettingsOpen = true
    }

    /// Closes the Settings modal (Escape, its close button, a click on its scrim, the Settings button) with any
    /// modal it opened above it (Generate Key, a profile's deletion), which would have nothing to return to.
    func closeSettings() {
        guard isSettingsOpen else { return }
        modal = nil
        isSettingsOpen = false
    }

    /// Shows Settings at `section`: the path a click on a Settings sidebar row takes (and a palette row, the
    /// profile chip's Edit Profiles…). The modal opens and the section switches in this call; a section whose data is
    /// still loading shows its placeholder in the same frame.
    func selectSettings(_ section: SettingsSection) {
        UITiming.select("settings \(section.rawValue)")
        openSettings()
        settingsSection = section
        settingsToken &+= 1
    }

    /// Settings shows with no modal over it: ⌘F searches its rows.
    var canFindInSettings: Bool { isSettingsOpen && modal == nil }

    /// ⌘F while Settings shows: opens and focuses its search.
    func findInSettings() {
        settingsSearchToken &+= 1
    }

    // MARK: Command palette

    /// Opens the command palette on the window's rows now (`PaletteCommands`), `query` typed; the card shows in this
    /// frame, its rows once ranked off the main actor.
    func openPalette(query: String = "") {
        // ⌘K and the toolbar's Search stay live over a modal: the palette waits until it closes.
        guard modal == nil, !isSettingsOpen, actionSession?.hasModal != true else { return }
        UITiming.select("palette")
        palette = CommandPaletteModel(snapshot: PaletteCommands.snapshot(for: self), query: query)
    }

    /// The palette, Settings or a modal shows: `MainView` blurs and disables the content behind it.
    var isShowingModal: Bool {
        palette != nil || isSettingsOpen || modal != nil || actionSession?.hasModal == true
    }

    // MARK: Modals

    /// Opens a window modal (a confirmation of a view, Generate Key): `ModalHost` shows it in this frame, over the
    /// content. The palette closes first: one modal at a time.
    func presentModal(_ modal: WindowModal) {
        palette = nil
        self.modal = modal
    }

    func closeModal() {
        modal = nil
    }

    /// ⌘K: opens the palette, or closes it when it is open.
    func togglePalette() {
        if palette == nil { openPalette() } else { closePalette() }
    }

    func closePalette() {
        palette = nil
    }

    /// Runs a row of the current results (Return or a click): the palette closes first, so a confirmation or form the
    /// action opens takes the focus. False when the row cannot run (disabled or stale); the palette stays open.
    @discardableResult
    func performPalette(_ item: PaletteItem) -> Bool {
        guard let action = palette?.action(for: item) else { return false }
        palette = nil
        action()
        return true
    }

    /// Routes a DEBUG `-HistqSelect` request through the same paths a click takes.
    func select(_ request: SelectRequest) {
        switch request.kind {
        case .tab:
            guard let index = request.value.flatMap(Int.init), tabs.indices.contains(index) else {
                Self.logger.error("-HistqSelect tab: no tab \(request.value ?? "", privacy: .public)")
                return
            }
            selectTab(at: index)
        case .archive:
            // `archive:<n>`: a click on the archive's row n; `archive` alone: the selected tab's Archive This Tab.
            guard let value = request.value else {
                if let selectedTabID { archiveTab(selectedTabID) }
                return
            }
            guard let index = Int(value), archivedTabs.indices.contains(index) else {
                Self.logger.error("-HistqSelect archive: no archived tab \(value, privacy: .public)")
                return
            }
            openArchived(at: index)
        case .settings:
            guard let value = request.value else {
                openSettings()
                return
            }
            guard let section = SettingsSection(rawValue: value) else {
                Self.logger.error("-HistqSelect settings: unknown section \(value, privacy: .public)")
                openSettings()
                return
            }
            selectSettings(section)
        case .sidebar:
            guard let session = selectedSession, let tab = request.value.flatMap(SidebarTab.init(selectValue:)) else {
                Self.logger.error("-HistqSelect sidebar: no repo tab or unknown tab \(request.value ?? "", privacy: .public)")
                return
            }
            session.selectSidebarTab(tab)
        case .branch:
            guard let session = selectedSession, let name = request.value else {
                Self.logger.error("-HistqSelect branch: no repo tab or no branch name")
                return
            }
            session.selectBranch(named: name)
        case .submodule:
            // `submodule:<path>`: a click on its sidebar row, at once (the detail reads the list when it is not in).
            guard let session = selectedSession, let path = request.value else {
                Self.logger.error("-HistqSelect submodule: no repo tab or no path")
                return
            }
            session.selectSubmodule(path)
        case .worktree, .openworktree, .branchclick:
            // `worktree:<folder name>`: a click on its sidebar row; `openworktree:<folder name>`: a double-click
            // (its tab opens); `branchclick:<name>`: a click on a branch's row. Once the worktrees are read.
            guard let session = selectedSession, let name = request.value else {
                Self.logger.error("-HistqSelect worktree: no repo tab or no worktree name")
                return
            }
            let opens = request.kind == .openworktree
            Task { [weak session] in
                for _ in 0..<250 {
                    guard let session else { return }
                    if request.kind == .branchclick, session.worktrees.value != nil {
                        return session.selectBranch(named: name)
                    }
                    if let info = session.worktrees.value?.first(where: { $0.name == name }) {
                        if opens { session.openWorktree(info.path) } else { session.selectWorktree(info) }
                        return
                    }
                    try? await Task.sleep(for: .milliseconds(20))
                }
                Self.logger.error("-HistqSelect worktree: no worktree \(name, privacy: .public)")
            }
        case .wip:
            guard let session = selectedSession else {
                Self.logger.error("-HistqSelect wip: no repo tab")
                return
            }
            session.selectGraph([.wip])
        case .commit:
            guard let session = selectedSession, let hash = request.value else {
                Self.logger.error("-HistqSelect commit: no repo tab or no commit")
                return
            }
            session.selectGraph([.commit(hash)])
        case .commits:
            // `commits:<sha>,<sha|wip>[,…][:<path>]`: several rows selected at once, as a shift- or cmd-click does,
            // once the refs and the log are in (a multi-selection's detail reads neither, so a first select would
            // leave the sidebar unread); with a path, then a click on that file of their combined diff once it loads.
            let parts = request.value?.split(separator: ":", maxSplits: 1).map(String.init) ?? []
            guard let session = selectedSession, let value = parts.first else {
                Self.logger.error("-HistqSelect commits: no repo tab or no commits")
                return
            }
            Task { [weak session] in
                for _ in 0..<150 {
                    guard let session else { return }
                    if session.refs.value != nil, session.log.value != nil { break }
                    try? await Task.sleep(for: .milliseconds(20))
                }
                session?.selectGraph(value.split(separator: ",").map { $0 == "wip" ? .wip : .commit(String($0)) })
                guard parts.count == 2 else { return }
                for _ in 0..<150 {
                    if case .multiple? = session?.detail.value { break }
                    try? await Task.sleep(for: .milliseconds(20))
                }
                try? await Task.sleep(for: .milliseconds(100))
                guard let session, case .multiple(_, let diff?, let files?)? = session.detail.value,
                      let file = files.first(where: { $0.path == parts[1] })
                else {
                    Self.logger.error("-HistqSelect commits: no combined diff with that file")
                    return
                }
                session.selectFile(FileTarget(source: .compare(base: diff.base, head: diff.head), file: file))
            }
        case .history:
            // `history:<path>`: the file's history, as its File History menu item opens it.
            guard let session = selectedSession, let path = request.value else {
                Self.logger.error("-HistqSelect history: no repo tab or no path")
                return
            }
            session.selectTool(.fileHistory(path: path, rev: nil, follow: false))
        case .file:
            guard let session = selectedSession, let path = request.value else {
                Self.logger.error("-HistqSelect file: no repo tab or no path")
                return
            }
            // A WIP file is clicked in the WIP panel: the WIP first, then the file once that panel is on screen, so
            // the `select file` line is timed like a user's click and not against the launch's first frames.
            session.selectGraph([.wip])
            Task { [weak session] in
                for _ in 0..<150 {
                    guard let session else { return }
                    if session.detail.value != nil { break }
                    try? await Task.sleep(for: .milliseconds(20))
                }
                try? await Task.sleep(for: .milliseconds(100))
                session?.selectWIPFile(path)
            }
        case .conflict:
            guard let session = selectedSession, let path = request.value else {
                Self.logger.error("-HistqSelect conflict: no repo tab or no path")
                return
            }
            // As `file:`: a conflicted file is clicked in the WIP panel, so the WIP shows first and the
            // `select conflict` line is timed like a user's click.
            session.selectGraph([.wip])
            Task { [weak session] in
                for _ in 0..<150 {
                    guard let session else { return }
                    if session.detail.value != nil { break }
                    try? await Task.sleep(for: .milliseconds(20))
                }
                try? await Task.sleep(for: .milliseconds(100))
                session?.selectConflict(path)
            }
        case .commitfile:
            // `commitfile:<sha>:<path>`: a click on the commit's row, then on the file in its file list once the
            // detail is on screen, with the `FileChange` that row holds.
            let parts = request.value?.split(separator: ":", maxSplits: 1).map(String.init) ?? []
            guard let session = selectedSession, parts.count == 2 else {
                Self.logger.error("-HistqSelect commitfile: no repo tab or not <sha>:<path>")
                return
            }
            session.selectGraph([.commit(parts[0])])
            Task { [weak session] in
                for _ in 0..<150 {
                    guard let session else { return }
                    // The header shows before the files: wait for them.
                    if session.detail.value?.isReady == true { break }
                    try? await Task.sleep(for: .milliseconds(20))
                }
                try? await Task.sleep(for: .milliseconds(100))
                guard let session, case .commit(let commit)? = session.detail.value, let files = commit.files else {
                    Self.logger.error("-HistqSelect commitfile: the commit's files did not load")
                    return
                }
                // A path the commit did not change opens as its row in "View all files" does.
                let file = files.first { $0.path == parts[1] } ?? FileChange(kind: .unchanged, path: parts[1])
                session.selectFile(FileTarget(source: .commit(commit.hash), file: file))
            }
        case .pr:
            // `pr:<n>`: the PRs tab, then a click on the row once its lists and the tab's first detail are in (3 s at
            // most; the placeholder shows whether the row is there or not), so the `select pr` line is timed like a
            // user's click and not against the launch's first frames.
            guard let session = selectedSession, let number = request.value.flatMap(Int.init) else {
                Self.logger.error("-HistqSelect pr: no repo tab or no number")
                return
            }
            session.selectSidebarTab(.prs)
            Task { [weak session] in
                for _ in 0..<150 {
                    guard let session else { return }
                    if session.github.isRead(.allOpen), session.detail.value != nil { break }
                    try? await Task.sleep(for: .milliseconds(20))
                }
                try? await Task.sleep(for: .milliseconds(100))
                guard let session else { return }
                session.selectHosted(session.github.item(numbered: number))
            }
        case .issue:
            // `issue:<n>`: as `pr:`, a click on the issue's row once the Issues list is in.
            guard let session = selectedSession, let number = request.value.flatMap(Int.init) else {
                Self.logger.error("-HistqSelect issue: no repo tab or no number")
                return
            }
            session.selectSidebarTab(.prs)
            Task { [weak session] in
                for _ in 0..<150 {
                    guard let session else { return }
                    if session.github.isRead(.assigned), session.detail.value != nil { break }
                    try? await Task.sleep(for: .milliseconds(20))
                }
                try? await Task.sleep(for: .milliseconds(100))
                session?.selectHosted(.issue(number))
            }
        case .prbadge:
            // `prbadge:<remote branch>` (`origin/feature`): a click on that branch's pull request chip in the graph,
            // once the graph and the badges are in; the chip's click calls the same `selectHosted`.
            guard let session = selectedSession, let branch = request.value else {
                Self.logger.error("-HistqSelect prbadge: no repo tab or no branch")
                return
            }
            Task { [weak session] in
                for _ in 0..<150 {
                    guard let session else { return }
                    if session.github.branchPullRequests[branch] != nil, session.detail.value != nil { break }
                    try? await Task.sleep(for: .milliseconds(20))
                }
                try? await Task.sleep(for: .milliseconds(100))
                guard let session, let pull = session.github.branchPullRequests[branch] else {
                    Self.logger.error("-HistqSelect prbadge: no open pull request on \(branch, privacy: .public)")
                    return
                }
                session.selectHosted(.pullRequest(pull.number))
            }
        }
    }
}

/// A tab's emoji, as Set Emoji… keeps it: one emoji `Character` (a flag or a ZWJ sequence is one, kept whole).
enum TabEmoji {
    /// The last emoji of `text` once trimmed (typing "a😀b🔥" gives "🔥"); nil when it has none ("1", plain text). A
    /// character counts when one of its scalars shows as an emoji by default, or is an emoji followed by U+FE0F
    /// (as "❤️").
    static func normalized(_ text: String) -> String? {
        text.trimmingCharacters(in: .whitespacesAndNewlines).reversed().first(where: isEmoji).map(String.init)
    }

    /// The character shows as an emoji (see `normalized`).
    private static func isEmoji(_ character: Character) -> Bool {
        let scalars = Array(character.unicodeScalars)
        return scalars.indices.contains { index in
            scalars[index].properties.isEmojiPresentation
                || (scalars[index].properties.isEmoji && index + 1 < scalars.count && scalars[index + 1] == "\u{FE0F}")
        }
    }
}
