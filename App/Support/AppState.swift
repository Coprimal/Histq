// App-wide state locations and DEBUG test seams: where files and preferences live, every preference key with its
// default, the Keychain service, launch flags, the `-HistqSelect` request and the timing log.
import Foundation
import HistqCore
import os

/// DEBUG launch flags and the values that depend on them (also honoured by a `HISTQ_PERF` measurement build). In
/// Release every flag reads as absent, so the app always uses the real Application Support folder, the standard
/// preferences and the real Keychain service.
enum AppState {
    /// The value after `name` in the launch arguments (`-HistqStateDir /path` -> "/path"), or nil when the flag is
    /// absent or has no value. DEBUG (or `HISTQ_PERF`) only: always nil in Release. Later phases read their own
    /// flags through it, at their point of use (`AppState.launchFlag("-HistqAvatarMode")`).
    static func launchFlag(_ name: String) -> String? {
        #if DEBUG || HISTQ_PERF
        let arguments = ProcessInfo.processInfo.arguments
        guard let index = arguments.firstIndex(of: name), index + 1 < arguments.count else { return nil }
        return arguments[index + 1]
        #else
        return nil
        #endif
    }

    /// DEBUG `-HistqBackground YES`: the app never activates itself, and its windows are ordered behind the others
    /// and never made key (with a state dir, on the "ARZOPA" display when connected), so a preview or a QA shot
    /// (`scripts/shot.sh` always passes it) never takes the user's focus or covers their work. Always false in Release.
    static let isBackgroundLaunch: Bool = launchFlag("-HistqBackground") == "YES"

    /// The folder given by DEBUG `-HistqStateDir <dir>`: automated launches keep all their state there (files,
    /// timing logs) and use the QA preferences suite and Keychain service. nil in normal runs.
    static let stateDirectory: URL? = launchFlag("-HistqStateDir").map {
        URL(fileURLWithPath: ($0 as NSString).expandingTildeInPath, isDirectory: true).standardizedFileURL
    }

    /// Whether this launch is isolated in a state dir (automated QA run).
    static var isStateDirMode: Bool { stateDirectory != nil }

    /// The Keychain service for every item the app stores.
    static var keychainService: String { isStateDirMode ? "com.math2it.histq.qa" : "com.math2it.histq" }

    /// The DEBUG `-HistqSelect <kind>[:<value>]` request of this launch, or nil.
    static let launchSelection: SelectRequest? = launchFlag("-HistqSelect").flatMap(SelectRequest.init(parsing:))

    /// DEBUG `-HistqDoubleClick toolbar|tabrow`: the row `DoubleClickProbe` double-clicks once the window is up.
    static let launchDoubleClick: String? = launchFlag("-HistqDoubleClick")

    /// DEBUG `-HistqToolbarFrames YES`: the toolbar logs its repo and branch dropdowns' frames (`HeaderToolbar`).
    static let launchToolbarFrames: Bool = launchFlag("-HistqToolbarFrames") == "YES"

    /// DEBUG `-HistqFind "<query>[;next|prev…]"`: once the log is read, the front repo tab's graph search opens as ⌘F
    /// opens it, the query is typed a character at a time, then each step runs (`AppDelegate.debugFind`).
    static let launchFind: String? = launchFlag("-HistqFind")

    /// DEBUG `-HistqFindEarly YES`: `-HistqFind` starts once the log's first page shows, not its whole log, and types
    /// the query at once (QA of a query typed while the log is still read).
    static let launchFindEarly: Bool = launchFlag("-HistqFindEarly") == "YES"

    /// DEBUG `-HistqSaveWorkspace <path>`: once the launch's windows are open, the front window's Save Workspace As…
    /// writes to `<path>` without a panel (`AppDelegate.saveWorkspace(to:from:)`).
    static let launchSaveWorkspace: String? = launchFlag("-HistqSaveWorkspace")

    /// DEBUG `-HistqCloseWorkspace <name>`: once the launch's windows are open, Close Workspace runs on the open
    /// workspace with that name.
    static let launchCloseWorkspace: String? = launchFlag("-HistqCloseWorkspace")
}

/// Where the app keeps its files: `~/Library/Application Support/Histq`, or the DEBUG state dir.
enum StatePaths {
    static let root: URL = AppState.stateDirectory
        ?? URL.applicationSupportDirectory.appending(path: "Histq", directoryHint: .isDirectory)

    /// `root/<name>`, created if missing (profiles, sessions, avatar cache, undo journals).
    static func directory(_ name: String) -> URL {
        let url = root.appending(path: name, directoryHint: .isDirectory)
        try? FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    /// Creates the root folder; called once at launch.
    static func prepare() {
        try? FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    }
}

/// The preferences store every setting reads and writes, `@AppStorage` included
/// (`@AppStorage(PrefKey.rowDensity.rawValue, store: Preferences.defaults)`).
enum Preferences {
    /// Standard defaults, or the `com.math2it.histq.qa` suite in state-dir mode, so QA runs never touch the user's
    /// settings (Debug and Release share the bundle id). UserDefaults is thread-safe (documented), so the
    /// `nonisolated(unsafe)` only covers its missing Sendable mark.
    nonisolated(unsafe) static let defaults: UserDefaults = AppState.isStateDirMode
        ? UserDefaults(suiteName: "com.math2it.histq.qa") ?? .standard
        : .standard

    /// Registers every `PrefKey` default, so a read of a key never set returns its default. Called once at launch.
    static func registerDefaults() {
        defaults.register(defaults: Dictionary(uniqueKeysWithValues: PrefKey.allCases.map { ($0.rawValue, $0.defaultValue) }))
        // Toasts "off" is gone (a failure shows only in its toast): it hides the successes only.
        if defaults.string(forKey: PrefKey.toastLevel.rawValue) == "off" {
            defaults.set(ToastLevel.errors.rawValue, forKey: PrefKey.toastLevel.rawValue)
        }
    }
}

/// Every preference key of the app, declared once with its default. The raw value is the stored key (written by
/// hand in QA runs: `defaults write com.math2it.histq.qa rowDensity -string compact`); choices are stored as
/// strings. Each consumer reads its key where it is built; the Settings pages only write them.
enum PrefKey: String, CaseIterable {
    /// Graph date column format (`DateFormatter.dateFormat`).
    case dateFormat
    /// Graph row height: "compact", "regular" or "comfortable".
    case rowDensity
    /// The graph's commit order: a `LogReader.Order` raw value, "date" (newest committer date first, every commit above
    /// its parents, so the branches interleave; `git log --date-order`) or "branch" (each line of history listed whole,
    /// `--topo-order`).
    case commitOrder
    /// The graph's lane colors: a `LaneColors` raw value, "vivid" (8 colors far apart, one per line) or "gradient"
    /// (10 colors in hue order, one per column).
    case laneColors
    /// The graph's, sidebar's and file lists' text: a `TextSize` raw value, "small", "regular" or "large".
    case textSize
    /// Commit avatars: "real" (Gravatar / GitHub), "generated" or "initials".
    case avatarMode
    /// Pull button: a `GitOperations.PullMode` case name, "fastForward" (merge if needed), "fastForwardOnly" or "rebase".
    case pullMode
    /// A checkout or pull with local changes: "ask" (the dialog), "always" (stash them first and put them back) or
    /// "never" (a checkout carries them, a pull runs without `--autostash`).
    case autoStash
    /// Auto-fetch interval in minutes; 0 = off.
    case autoFetchMinutes
    /// `fetch --prune` on every fetch.
    case pruneOnFetch
    /// After a checkout, pull, merge, rebase, reset, cherry-pick, revert, undo or redo, the clean submodules move to the
    /// commits this repository records (`RepoSession.autoUpdateSubmodules`).
    case autoUpdateSubmodules
    /// `git mergetool --tool=<value>`; empty = git's configured tool.
    case mergeTool
    /// Custom git executable path; empty = auto-detect.
    case gitPath
    /// The profile new tabs use (UUID string); empty = none yet.
    case defaultProfileID
    /// App tab strip position: "top" or "left".
    case tabPosition
    /// The emoji a repo tab without its own emoji or icon color shows instead of the book (`TabIcon`); empty = the book.
    case defaultTabEmoji
    /// The book's color for a repo tab without its own: an index into `Palette.graphLanes`; -1 = the text's color.
    case defaultTabIconColor
    /// Native window tabs in the traffic-light row (Phase 8 attempt).
    case nativeTabsOnTop
    /// Repo layout panel widths, encoded by `RepoLayoutView`; empty = the layout's defaults.
    case panelWidths
    /// The file history's commit list (panel 1 while a file history shows), in points; 0 = the layout's default.
    case historyPanelWidth
    /// Repo layout preset: a `LayoutPreset` raw value, "classic", "stacked", "focus" or "columns". Global, like
    /// `panelWidths`.
    case layoutPreset
    /// The cards on the page's sheet draw their 1 pt `Palette.sheetCardBorder` edge; off, no edge.
    case cardBorders
    /// Stacked's split: the graph's share of panel 2's height above the bottom pane, 0...1. Global.
    case stackedSplit
    /// The preset leaving Focus returns to: "classic", "stacked" or "columns" (never "focus"), set when Focus turns
    /// on. Global.
    case presetBeforeFocus
    /// Columns' panel widths, "sidebar,detail,diff" in points; empty = the layout's defaults. Global, kept apart
    /// from `panelWidths` (Classic, Stacked and Focus).
    case columnsWidths
    /// A repo tab shows its sidebar (panel 1) and its detail (panel 3): the toolbar's Sidebar and Detail toggles.
    /// Global, like `layoutPreset`; Focus hides both whatever they are.
    case showSidebar
    case showDetail
    /// The sidebar's sections in the user's order, inside each tab: section ids separated by commas, "local", "remote",
    /// "worktrees" (Branches), "tags" (Tags), "mine", "reviewRequested", "allOpen", "assigned" (PRs); empty = the
    /// default order. Read by `SidebarSections`. Global.
    case sidebarSectionOrder
    /// The sidebar sections hidden: section ids separated by commas, as `sidebarSectionOrder`; empty = none. Hiding
    /// Tags, or all four PR lists, removes their tab. Global.
    case hiddenSidebarSections
    /// Graph column widths, encoded by `GraphView` ("refs:120,graph:120,…"); empty = the graph's defaults.
    case graphColumnWidths
    /// The graph's Commit message, Author and Time columns show (Branch / Tag and Graph always do).
    case graphShowMessage
    case graphShowAuthor
    case graphShowDate
    /// In a worktree's tab, the graph fades the other worktrees' branches from where they fork off its history, until
    /// one of their rows is selected (`WorktreeMap`). Off: only their WIP rows fade.
    case graphFadeOtherWorktrees
    /// Terminal font family; empty = the system monospaced font.
    case terminalFontName
    /// Terminal font size in points.
    case terminalFontSize
    /// Terminal shell path; empty = the user's login shell.
    case terminalShell
    /// Terminal scrollback lines.
    case terminalScrollback
    /// Terminal cursor: "block", "underline" or "bar".
    case terminalCursor
    /// Terminal output keeps its bold text; off draws it in the normal weight (`SGRBoldFilter`).
    case terminalBoldText
    /// Open the terminal drawer with each new tab.
    case terminalOpenWithNewTab
    /// The Welcome page's recent repositories: folder paths, most recent first (`RecentRepos`).
    case recentRepos
    /// Recent Workspaces: workspace file paths, most recent first (`RecentRepos.workspaces`).
    case recentWorkspaces
    /// The detail panel's file lists: "tree" (rows under their folders) or "path" (one row per file). Settings ›
    /// Appearance sets it for every card; each files card keeps its own (`FileListCard.key`), switched from its header.
    case fileListMode
    /// A commit's Files card lists every file of the commit's tree, the unchanged ones dimmed ("View all files"); its
    /// header switches it.
    case commitShowsAllFiles
    /// The Unstaged card shows each file's size (and a folder's total in the tree).
    case showFileSizes
    /// The WIP panel's commit box: "bottom" (under the file cards) or "top" (above them).
    case commitBoxPosition
    /// The Staged card, in the WIP panel and another worktree's changes: "below" or "above" the Unstaged card.
    case stagedPosition
    /// The file diffs ignore whitespace changes (`git diff -w`); their hunks are then read-only.
    case diffIgnoreWhitespace
    /// The file diffs wrap long lines instead of scrolling sideways.
    case diffWrapLines
    /// The view a newly opened repository's diffs start in: a `DiffMode` raw value, "diff", "split" or "full";
    /// switching in an open diff changes only that window's session.
    case diffDefaultMode
    /// The blame wraps long lines instead of scrolling sideways; its header switches it.
    case blameWrapLines
    /// The code's font size in points (the diffs, the blame and the conflict editor): 11, 12, 13, 14 or 16.
    case codeFontSize
    /// The AI buttons (Explain, Generate Message, Suggest Resolution) are shown; off hides them all.
    case aiShowFeatures
    /// The AI provider the hooks use: an `AIProvider` raw value ("openAI", "anthropic", "gemini", "xAI", "custom").
    case aiProvider
    /// The model of each AI provider, by `AIProvider` raw value; a missing or empty one = the provider's default.
    case aiModels
    /// The custom AI provider's base URL as typed (validated with `AIEndpoint.normalize` where it is used).
    case aiCustomBaseURL
    /// The language of the AI explanations (Explain): an `AIResponseLanguage` raw value ("english", "vietnamese", …).
    case aiResponseLanguage
    /// The language of the AI commit messages (Generate Message): an `AIResponseLanguage` raw value.
    case aiCommitLanguage
    /// Generate Message writes the summary line only, no description.
    case aiCommitSummaryOnly
    /// The user's own instructions added to the Generate Message prompt (empty: none).
    case aiCommitInstructions
    /// The user's own instructions added to the Explain prompts, for a commit and for the changes (empty: none).
    case aiExplainInstructions
    /// The user's own instructions added to the Suggest Resolution prompt (empty: none).
    case aiConflictInstructions
    /// The user's own instructions added to the pull request Generate prompt (empty: none).
    case aiPullRequestInstructions
    /// The operation toasts shown: a `ToastLevel` raw value, "all" or "errors" (a failure always shows).
    case toastLevel
    /// The refs an earlier build hid, full ref names by repo folder path: only read once per folder, to move them into
    /// its `RepoViewState` (`RepoSession.migrateHiddenRefs`).
    case hiddenRefs

    /// The value a key has until the user sets it.
    var defaultValue: Any {
        switch self {
        case .dateFormat: "MM/dd/yy @ HH:mm"
        case .rowDensity: "regular"
        case .commitOrder: "date"
        case .laneColors: "vivid"
        case .textSize: "regular"
        case .avatarMode: "generated"
        case .pullMode: "fastForward"
        case .autoStash: "ask"
        case .autoFetchMinutes: 3
        case .pruneOnFetch: false
        case .autoUpdateSubmodules: true
        case .mergeTool: ""
        case .gitPath: ""
        case .defaultProfileID: ""
        case .tabPosition: "top"
        case .defaultTabEmoji: ""
        case .defaultTabIconColor: -1
        case .nativeTabsOnTop: false
        case .panelWidths: ""
        case .historyPanelWidth: 0.0
        case .layoutPreset: "classic"
        case .stackedSplit: 0.45
        case .presetBeforeFocus: "classic"
        case .cardBorders: true
        case .columnsWidths: ""
        case .showSidebar, .showDetail: true
        case .sidebarSectionOrder, .hiddenSidebarSections: ""
        case .graphColumnWidths: ""
        case .graphShowMessage, .graphShowAuthor, .graphShowDate: true
        case .graphFadeOtherWorktrees: true
        case .terminalFontName: ""
        case .terminalFontSize: 12.0
        case .terminalShell: ""
        case .terminalScrollback: 10_000
        case .terminalCursor: "block"
        case .terminalBoldText: false
        case .terminalOpenWithNewTab: false
        case .recentRepos, .recentWorkspaces: [String]()
        case .fileListMode: "tree"
        case .commitShowsAllFiles: false
        case .showFileSizes: true
        case .commitBoxPosition: "bottom"
        case .stagedPosition: "below"
        case .diffIgnoreWhitespace, .diffWrapLines: false
        case .diffDefaultMode: "diff"
        case .blameWrapLines: false
        case .codeFontSize: 12.0
        case .aiShowFeatures: true
        case .aiProvider: "openAI"
        case .aiModels: [String: String]()
        case .aiCustomBaseURL: ""
        case .aiResponseLanguage: "english"
        case .aiCommitLanguage: "english"
        case .aiCommitSummaryOnly: false
        case .aiCommitInstructions, .aiExplainInstructions, .aiConflictInstructions, .aiPullRequestInstructions: ""
        case .toastLevel: "all"
        case .hiddenRefs: [String: [String]]()
        }
    }
}

/// How a repo tab lays out its panels (`PrefKey.layoutPreset`). Classic: sidebar | graph | detail, a file opens over
/// the graph. Stacked: a file opens in a pane under the graph. Focus: sidebar and detail collapse, panel 2 goes full
/// width. Columns: a file opens in a 4th column next to the detail, the graph stays visible.
enum LayoutPreset: String {
    case classic, stacked, focus, columns

    /// DEBUG `-HistqLayout classic|stacked|focus|columns`, read once. It wins over the preference (as
    /// `-HistqTabPosition` does) and is never written to it.
    private static let launchOverride = AppState.launchFlag("-HistqLayout").flatMap(LayoutPreset.init(rawValue:))

    /// The preset for a stored `PrefKey.layoutPreset` value; anything unknown reads as classic.
    static func resolved(_ stored: String) -> LayoutPreset {
        launchOverride ?? LayoutPreset(rawValue: stored) ?? .classic
    }

    /// The preset for the preference stored now.
    static var current: LayoutPreset {
        resolved(Preferences.defaults.string(forKey: PrefKey.layoutPreset.rawValue) ?? "")
    }

    /// Switches to `preset` (View menu, palette, Settings › Appearance); the windows follow it live. Focus while in
    /// Focus (⌥⌘F again) returns to the preset used before it, which turning Focus on remembers.
    static func choose(_ preset: LayoutPreset) {
        let defaults = Preferences.defaults
        let stored = LayoutPreset(rawValue: defaults.string(forKey: PrefKey.layoutPreset.rawValue) ?? "") ?? .classic
        var next = preset
        if preset == .focus, stored == .focus {
            next = LayoutPreset(rawValue: defaults.string(forKey: PrefKey.presetBeforeFocus.rawValue) ?? "")
                .flatMap { $0 == .focus ? nil : $0 } ?? .classic
        } else if preset == .focus {
            defaults.set(stored.rawValue, forKey: PrefKey.presetBeforeFocus.rawValue)
        }
        defaults.set(next.rawValue, forKey: PrefKey.layoutPreset.rawValue)
    }

    /// View › Reset Layout: the default panel widths (the file history's and Columns' too) and Stacked split, both
    /// side panels shown. The preset stays, and so does the one Focus returns to.
    static func reset() {
        for key in [PrefKey.panelWidths, .historyPanelWidth, .stackedSplit, .columnsWidths, .showSidebar, .showDetail] {
            Preferences.defaults.removeObject(forKey: key.rawValue)
        }
    }
}

/// A DEBUG `-HistqSelect <kind>[:<value>]` request (`tab:1`, `wip`, `commit:<sha>`, `file:src/app.swift`,
/// `settings:profiles`). The window routes it through the same `select` path a click takes.
struct SelectRequest: Equatable, Sendable {
    enum Kind: String, CaseIterable, Sendable {
        case tab, wip, commit, commits, branch, branchclick, worktree, openworktree, file, conflict, commitfile,
            history, settings, sidebar, pr, issue, prbadge, archive, submodule
    }

    let kind: Kind
    /// The text after the first colon (paths and refs may hold more colons), or nil.
    let value: String?

    /// Parses `kind[:value]`; an unknown kind is logged and gives nil.
    init?(parsing text: String) {
        let parts = text.split(separator: ":", maxSplits: 1, omittingEmptySubsequences: false)
        guard let kind = Kind(rawValue: String(parts[0])) else {
            Logger(subsystem: "com.math2it.histq", category: "launch")
                .error("-HistqSelect: unknown kind in \(text, privacy: .public), ignored")
            return nil
        }
        self.kind = kind
        value = parts.count > 1 && !parts[1].isEmpty ? String(parts[1]) : nil
    }
}

/// DEBUG timing log for the click-first checks: each line is `<ms since launch> <event> <detail>`, appended to
/// `<stateDir>/timing.log` (`refresh` lines to `<stateDir>/refresh.log`) when `-HistqStateDir` is set, and mirrored
/// to the unified log (category "timing", `.notice`). Callable from any thread; every function is a no-op in
/// Release (unless built with `HISTQ_PERF`), so call sites need no `#if DEBUG`.
enum UITiming {
    /// A repo was opened in a tab.
    static func open(_ detail: String) { record("open", detail) }
    /// The selection changed (`select tab 1`, `select commit <sha>`).
    static func select(_ detail: String) { record("select", detail) }
    /// The detail's placeholder is on screen.
    static func placeholder(_ detail: String) { record("placeholder", detail) }
    /// The delayed spinner faded in (the load took over ~150 ms).
    static func spinner(_ detail: String) { record("spinner", detail) }
    /// The detail's content is on screen.
    static func content(_ detail: String) { record("content", detail) }
    /// A commit's info card (subject, people, sha, parents) is on screen; its files may still be loading.
    static func contentInfo(_ detail: String) { record("content-info", detail) }
    /// The commit detail's Files card in the detail panel: `layout <detail> <state> filesTop=<y> filesBottom=<y>
    /// panelBottom=<y>`.
    static func layout(_ detail: String) { record("layout", detail) }
    /// A repo's whole log has been parsed and laid out: `content log-complete <commit count>`, then a `mem` line.
    static func logComplete(commitCount: Int) {
        record("content", "log-complete \(commitCount)")
        memory()
    }
    /// A repo's log was read again after a change: `content log-reload incremental <new commits> <ms> env=<ms>
    /// stashes=<ms> tips=<ms> delta=<ms> concat=<ms> index=<ms> layout=<ms>` when only the new commits were read,
    /// `content log-reload full <ms>` when the whole history was.
    static func logReload(_ detail: String) { record("content", "log-reload \(detail)") }
    /// A log load started: `log-start <generation> incremental` when it first tries to read only the new commits,
    /// `log-start <generation> full` when it reads the whole history.
    static func logStart(generation: Int, incremental: Bool) {
        record("log-start", "\(generation) " + (incremental ? "incremental" : "full"))
    }
    /// A finished load started another: `log-again synthetic` (a new log load: the WIP or stash rows changed
    /// meanwhile) or `log-again worktree` (a new layout for the other worktrees' rows).
    static func logAgain(_ reason: String) { record("log-again", reason) }
    /// The main-actor work after a log load (publish, selection check, branch map start): `log-publish <ms>`.
    static func logPublish(since start: UInt64) { record("log-publish", ms(since: start)) }
    /// The branch attribution of a log started: `branch-map-start <log generation>`.
    static func branchMapStart(generation: Int) { record("branch-map-start", "\(generation)") }
    /// The graph's branch attribution (`BranchAttribution`) is computed: `content branch-map <commits> <ms>`.
    static func branchMap(count: Int, ms: Double) {
        record("content", "branch-map \(count) " + String(format: "%.1f", ms))
    }
    /// A branch attribution was computed but a newer one replaced it: `content branch-map cancelled <ms>`.
    static func branchMapCancelled(ms: Double) {
        record("content", "branch-map cancelled " + String(format: "%.1f", ms))
    }
    /// A refresh read the status and the refs: `refresh-read <ms>`.
    static func refreshRead(since start: UInt64) { record("refresh-read", ms(since: start)) }
    /// The graph table reloaded for a new log generation: `graph-reload <generation> <ms>`.
    static func graphReload(generation: Int, since start: UInt64) {
        record("graph-reload", "\(generation) " + ms(since: start))
    }
    /// The repo watcher triggered a refresh (`status`, `refs`, `log`, `status+refs`); goes to `refresh.log`.
    static func refresh(_ scope: String) { record("refresh", scope, file: "refresh.log") }
    /// DEBUG double-click probe (`DoubleClickProbe`): `click …` for a mouse-down, `dblclick …` for a seam run.
    static func probe(_ event: String, _ detail: String) { record(event, detail) }
    /// DEBUG `-HistqSelectWalk`: `walk start <n> every <ms> ms`, then `walk done`.
    static func walk(_ detail: String) { record("walk", detail) }
    /// The selected tab's area changed to another tab: `tab-shown <index> <repo>`.
    static func tabShown(_ detail: @autoclosure () -> String) {
        #if DEBUG || HISTQ_PERF
        record("tab-shown", detail())
        #endif
    }
    /// A tab's view took the keyboard focus on purpose: `focus <repo> <kind>`, `kind` `search`, `diff`, `blame` or
    /// `graph`; `none` when its terminal closed and the focus stayed where it was, or a tab switch left it on the window
    /// (`WindowModel.focusShownTab`, once per switch).
    static func focus(_ repo: String, _ kind: String) {
        #if DEBUG || HISTQ_PERF
        record("focus", "\(repo) \(kind)")
        #endif
    }
    /// DEBUG `-HistqTabWalk`: the main actor's holds in the 500 ms after a tab switch: `tab-frame <index> max=<ms>
    /// over16=<ms>`.
    static func tabFrame(_ detail: String) { record("tab-frame", detail) }
    /// A file diff (commit, WIP or compare) was read: `file-load <path> env=<ms> size=<ms> diff=<ms> rows=<ms>
    /// lines=<n>`, `n` the file's line count.
    static func fileLoad(_ detail: @autoclosure () -> String) {
        #if DEBUG || HISTQ_PERF
        record("file-load", detail())
        #endif
    }
    /// A new id for an operation's `op-*` lines, unique across tabs (the first is 1).
    @MainActor static func nextOpID() -> Int {
        lastOpID &+= 1
        return lastOpID
    }
    @MainActor private static var lastOpID = 0
    /// A user operation was clicked, before any state change: `op-click <id> <kind> <repo>`, `kind` the `Write` case.
    static func opClick(_ id: Int, _ write: @autoclosure () -> Any, repo: @autoclosure () -> String) {
        #if DEBUG || HISTQ_PERF
        record("op-click", "\(id) \(kind(of: write())) \(repo())")
        #endif
    }
    /// The operation's `perform` started: `op-start <id> <kind> <repo>`.
    static func opStart(_ id: Int, _ write: @autoclosure () -> Any, repo: @autoclosure () -> String) {
        #if DEBUG || HISTQ_PERF
        record("op-start", "\(id) \(kind(of: write())) \(repo())")
        #endif
    }
    /// The operation's git work returned or threw: `op-end <id> ok|fail`.
    static func opEnd(_ id: Int, ok: Bool) {
        #if DEBUG || HISTQ_PERF
        record("op-end", "\(id) " + (ok ? "ok" : "fail"))
        #endif
    }
    /// The reread after the operation published the status and the refs: `op-settled <id>`.
    static func opSettled(_ id: Int) {
        #if DEBUG || HISTQ_PERF
        record("op-settled", "\(id)")
        #endif
    }
    /// The UI showed an operation's first feedback: `op-feedback status <title>`, `op-feedback toolbar <label>`, ….
    static func opFeedback(_ detail: @autoclosure () -> String) {
        #if DEBUG || HISTQ_PERF
        record("op-feedback", detail())
        #endif
    }
    /// A child git process finished (`GitRunner.processObserver`): `git <verb> <ms> <repo>[ exit=<code>][ signal=<n>]`.
    static func git(_ verb: String, ms: Double, repo: String, exit: Int32, signal: Int32?) {
        #if DEBUG || HISTQ_PERF
        let end = signal.map { " signal=\($0)" } ?? (exit != 0 ? " exit=\(exit)" : "")
        record("git", "\(verb) " + String(format: "%.1f", ms) + " \(repo)" + end)
        #endif
    }
    /// DEBUG `-HistqToolbarFrames`: `toolbar repo=<x>,<w> branch=<x>,<w>`, the dropdowns' frames in the window.
    static func toolbar(_ detail: String) { record("toolbar", detail) }
    /// The graph search (⌘F) landed on a result or moved to a match: `find <query> matches=<m> current=<n>
    /// commit=<sha>` (`GraphSearch`).
    static func find(_ detail: String) { record("find", detail) }
    /// The process's memory in MB: `mem footprint=<MB> peak=<MB>`, the current `phys_footprint` and its lifetime
    /// peak (`ledger_phys_footprint_peak`) from `task_info(TASK_VM_INFO)`.
    static func memory() {
        #if DEBUG || HISTQ_PERF
        var info = task_vm_info_data_t()
        var count = mach_msg_type_number_t(MemoryLayout<task_vm_info_data_t>.size / MemoryLayout<natural_t>.size)
        let result = withUnsafeMutablePointer(to: &info) {
            $0.withMemoryRebound(to: integer_t.self, capacity: Int(count)) {
                task_info(mach_task_self_, task_flavor_t(TASK_VM_INFO), $0, &count)
            }
        }
        guard result == KERN_SUCCESS else { return }
        let mb: (UInt64) -> String = { String(format: "%.1f", Double($0) / 1_048_576) }
        record("mem", "footprint=\(mb(info.phys_footprint)) peak=\(mb(UInt64(info.ledger_phys_footprint_peak)))")
        #endif
    }

    /// A `Write`'s case name (`stashPush` of `stashPush(…)`).
    private static func kind(of write: Any) -> String {
        String(String(describing: write).prefix { $0 != "(" })
    }

    /// The ms since `start` (uptime nanoseconds), for a timing line.
    private static func ms(since start: UInt64) -> String {
        String(format: "%.1f", Double(DispatchTime.now().uptimeNanoseconds &- start) / 1_000_000)
    }

    /// The step times of one task for its timing line: `lap("tips")` adds the ms since the last lap (or since `init`)
    /// to step "tips"; `description` is `<step>=<ms> …` in the order the steps first ended. Times nothing in Release.
    struct Steps: Sendable {
        private var last = DispatchTime.now().uptimeNanoseconds
        private var names: [String] = []
        private var ms: [String: Double] = [:]

        mutating func lap(_ name: String) {
            #if DEBUG || HISTQ_PERF
            let now = DispatchTime.now().uptimeNanoseconds
            if ms[name] == nil { names.append(name) }
            ms[name, default: 0] += Double(now &- last) / 1_000_000
            last = now
            #endif
        }

        var description: String {
            names.map { "\($0)=" + String(format: "%.1f", ms[$0] ?? 0) }.joined(separator: " ")
        }
    }

    #if DEBUG || HISTQ_PERF
    /// The launch origin, in uptime nanoseconds; set by `markLaunch()` at the top of `main()`.
    nonisolated(unsafe) private static var launchNanos = DispatchTime.now().uptimeNanoseconds
    private static let logger = Logger(subsystem: "com.math2it.histq", category: "timing")
    /// Writes in call order without blocking the caller.
    private static let queue = DispatchQueue(label: "com.math2it.histq.timing")
    #endif

    /// Sets the "ms since launch" origin. Call once, first thing in `main()`, before any other thread exists.
    static func markLaunch() {
        #if DEBUG || HISTQ_PERF
        launchNanos = DispatchTime.now().uptimeNanoseconds
        GitRunner.processObserver = { verb, ms, repo, exit, signal in
            git(verb, ms: ms, repo: repo, exit: exit, signal: signal)
        }
        #endif
    }

    private static func record(_ event: String, _ detail: String, file: String = "timing.log") {
        #if DEBUG || HISTQ_PERF
        let ms = Double(DispatchTime.now().uptimeNanoseconds &- launchNanos) / 1_000_000
        let line = String(format: "%.1f", ms) + " \(event) \(detail)"
        logger.notice("\(line, privacy: .public)")
        guard let directory = AppState.stateDirectory else { return }
        let path = directory.appending(path: file).path
        queue.async {
            // Opened per line with O_APPEND: the file may be truncated by a test while the app runs, and the app
            // may be killed at any moment.
            let fd = Darwin.open(path, O_WRONLY | O_APPEND | O_CREAT, 0o644)
            guard fd >= 0 else { return }
            let bytes = Array((line + "\n").utf8)
            _ = bytes.withUnsafeBytes { Darwin.write(fd, $0.baseAddress, $0.count) }
            Darwin.close(fd)
        }
        #endif
    }
}
