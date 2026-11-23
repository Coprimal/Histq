// The spotlight tour's stops, in order: what each one frames (`SpotlightTarget`, whose case name is the stop's id, as
// in `-HistqOnboarding tour:graph`), what its popover says, what it sets up first on the demo tab's session (a sidebar
// tab, the WIP row, a commit: selections only, never a git write) and when the layout leaves it out. The tour also
// skips a stop whose target has no frame once its `prepare` ran and the window laid out (`TourStop.resolves(frame:)`).
import Foundation

/// What decides which stops a tour has, read once when it starts.
struct TourContext {
    var layout: LayoutPreset
    var tabPosition: TabPosition
    /// Settings › AI › Show AI features: the commit box's stop names Generate Message only when it shows.
    var showsAI: Bool
    /// Whether the window is a workspace's, so the toolbar shows the workspace menu; in an Untitled window it is
    /// hidden and the repository menu's stop says what a workspace is.
    var hasWorkspace: Bool

    @MainActor
    static func current(_ model: WindowModel) -> TourContext {
        TourContext(layout: .current, tabPosition: .current,
                    showsAI: Preferences.defaults.bool(forKey: PrefKey.aiShowFeatures.rawValue),
                    hasWorkspace: model.workspace != nil)
    }
}

/// One stop of the tour: a target, its popover's copy and what to select before it shows.
struct TourStop: Identifiable {
    let target: SpotlightTarget
    let title: String
    let message: String
    /// SF Symbols or Lucide assets (`IconImage`), shown as chips under the text.
    var icons: [String] = []
    /// Run on the demo tab's session before the spotlight moves here, on Next, Back or a `tour:<id>` launch alike, so
    /// each stop sets the selection it needs itself.
    var prepare: (@MainActor (RepoSession) -> Void)?

    /// The `-HistqOnboarding tour:<id>` id.
    var id: String { target.rawValue }

    var popover: SpotlightPopover { SpotlightPopover(title: title, message: message, icons: icons) }

    /// Whether the tour shows this stop when its target is at `frame` (the registry's, read after `prepare` and a
    /// layout pass). A content target needs a frame, and so does a toolbar dropdown (it has a view on every macOS, so
    /// nil means hidden or removed). The other toolbar items have views only on macOS 26: there nil means removed or in
    /// the overflow menu; before it they never have one, and the popover anchors to the toolbar band.
    @MainActor
    func resolves(frame: CGRect?) -> Bool {
        if frame != nil { return true }
        return target.isToolbar && !target.isToolbarDropdown && !PlatformFeatures.liquidGlass
    }
}

@MainActor
enum TourStops {
    /// Every stop's target in tour order, those a context leaves out too, so a `tour:<id>` launch for a left-out
    /// stop starts at the next one (`index(of:in:)`).
    static let order: [SpotlightTarget] = [
        .repoMenu, .workspaceMenu, .branchMenu, .profile, .sync, .branchActions, .history, .tabStrip, .verticalTabs,
        .sidebarRefs, .sidebarStashesWorktrees, .sidebarPRs, .graph, .detail, .wipRow, .staging, .commitBox,
        .terminal, .search,
    ]

    /// The stops for `context`, in tour order.
    static func stops(_ context: TourContext) -> [TourStop] {
        order.compactMap { stop($0, context) }
    }

    /// Where the tour starts for a `tour:<id>` launch: the index in `stops` of the stop `id` names or, when the context
    /// left it out, of the first stop after it; nil for an unknown id or when no stop follows.
    static func index(of id: String, in stops: [TourStop]) -> Int? {
        guard let target = SpotlightTarget(rawValue: id), let start = order.firstIndex(of: target) else { return nil }
        let fromThere = Set(order[start...])
        return stops.firstIndex { fromThere.contains($0.target) }
    }

    /// `target`'s stop, or nil when `context` leaves it out: the workspace menu outside a workspace window, the tab
    /// strip or the vertical tabs (whichever does not show), and in Focus the sidebar's and the detail panel's stops
    /// (the WIP panel is the detail panel's).
    private static func stop(_ target: SpotlightTarget, _ context: TourContext) -> TourStop? {
        let sidePanels = context.layout != .focus
        let left = context.tabPosition == .left
        return switch target {
        case .repoMenu: repoMenu(hasWorkspace: context.hasWorkspace)
        case .workspaceMenu: context.hasWorkspace ? workspaceMenu : nil
        case .branchMenu: branchMenu
        case .profile: profile
        case .sync: sync
        case .branchActions: branchActions
        case .history: history
        case .tabStrip: left ? nil : tabs(.tabStrip)
        case .verticalTabs: left ? tabs(.verticalTabs) : nil
        case .sidebarRefs: sidePanels ? sidebarRefs : nil
        case .sidebarStashesWorktrees: sidePanels ? sidebarStashesWorktrees : nil
        case .sidebarPRs: sidePanels ? sidebarPRs : nil
        case .graph: graph
        case .detail: sidePanels ? detail : nil
        case .wipRow: wipRow
        case .staging: sidePanels ? staging : nil
        case .commitBox: sidePanels ? commitBox(showsAI: context.showsAI) : nil
        case .terminal: terminal
        case .search: search
        case .terminalDrawer: nil
        }
    }

    // MARK: Toolbar

    private static func repoMenu(hasWorkspace: Bool) -> TourStop {
        TourStop(
            target: .repoMenu, title: "Repository",
            message: "The repository in this tab. Its menu switches tabs, opens a recent repository or another "
                + "folder, and has this repository's own commands."
                + (hasWorkspace ? "" : " File › Save Workspace As… keeps a window's tabs in a workspace file."),
            icons: ["book.closed"])
    }

    private static let workspaceMenu = TourStop(
        target: .workspaceMenu, title: "Workspace",
        message: "This window's workspace: a file that keeps its tabs. Its menu reveals the file, saves a copy, "
            + "closes it or opens another workspace.",
        icons: ["square.stack.3d.up"])

    private static let branchMenu = TourStop(
        target: .branchMenu, title: "Branch",
        message: "The branch checked out here. Pick another branch in its menu to check it out.",
        icons: ["lucide-git-branch"])

    private static let profile = TourStop(
        target: .profile, title: "Profile",
        message: "The tab's profile: the name and email its commits are made with, and its signing and SSH keys. "
            + "Pick another one here, or None to use your own git config.",
        icons: ["person.crop.circle"])

    private static let sync = TourStop(
        target: .sync, title: "Pull, Push and Fetch",
        message: "Pull updates the current branch, Push sends your commits, and Fetch reads every remote without "
            + "changing your branches. They need a remote, which this demo does not have.",
        icons: [ToolbarAction.pull.systemImage, ToolbarAction.push.systemImage, ToolbarAction.fetch.systemImage])

    private static let branchActions = TourStop(
        target: .branchActions, title: "Branch, Stash and Pop",
        message: "Branch makes a new branch at the current commit, Stash puts every change aside, and Pop brings the "
            + "newest stash back.",
        icons: [ToolbarAction.branch.systemImage, ToolbarAction.stash.systemImage, ToolbarAction.pop.systemImage])

    private static let history = TourStop(
        target: .history, title: "Undo and Redo",
        message: "Undo takes back the last local operation Histq ran in this repository, such as a commit or a "
            + "discard, and Redo puts it back. ⌘Z does the same in the graph.",
        icons: ["arrow.uturn.backward", "arrow.uturn.forward"])

    private static let terminal = TourStop(
        target: .terminal, title: "Terminal",
        message: "Opens a terminal under the graph, in the repository's folder, with your own shell (⌃`).",
        icons: ["terminal"])

    private static let search = TourStop(
        target: .search, title: "Command Palette",
        message: "Search opens the command palette (⌘K): type to find a command, a branch, a tab or a setting. "
            + "Many settings change right there, without opening Settings.",
        icons: ["command"])

    // MARK: Tabs and sidebar

    private static func tabs(_ target: SpotlightTarget) -> TourStop {
        TourStop(
            target: target, title: "Tabs",
            message: "Each repository opens in its own tab. Right-click a tab to set an emoji, pin it, add it to a "
                + "group, or archive it: the archive button brings it back.",
            icons: ["pin", "archivebox"])
    }

    private static let sidebarRefs = TourStop(
        target: .sidebarRefs, title: "Branches and Tags",
        message: "Your branches, and the tags on their own tab. Click one to jump to its commit, double-click to "
            + "check it out. Right-click a branch › Hide takes it out of the sidebar and the graph.",
        icons: [SidebarMetrics.localImage, SidebarMetrics.remoteImage, "tag"],
        prepare: { $0.selectSidebarTab(.branches) })

    private static let sidebarStashesWorktrees = TourStop(
        target: .sidebarStashesWorktrees, title: "Stashes and Worktrees",
        message: "Your stashes and the repository's worktrees. Double-click a worktree to open it in a tab. A "
            + "repository with submodules lists them here too.",
        icons: [SidebarMetrics.stashImage, SidebarMetrics.worktreeImage, SidebarMetrics.submoduleImage],
        prepare: { $0.selectSidebarTab(.branches) })

    private static let sidebarPRs = TourStop(
        target: .sidebarPRs, title: "Pull Requests and Issues",
        message: "A GitHub repository's pull requests and issues, once your account is connected in Settings › "
            + "Integrations. This demo is not on GitHub, so the tab has none.",
        icons: ["lucide-git-pull-request-arrow"],
        prepare: { $0.selectSidebarTab(.prs) })

    // MARK: Graph and detail

    private static let graph = TourStop(
        target: .graph, title: "Commit Graph",
        message: "Every commit, with a colored lane for each line of work. Drag a branch's label onto another "
            + "branch's label to merge or rebase it. Right-click a commit or a label for everything else.",
        icons: ["lucide-git-branch"])

    private static let detail = TourStop(
        target: .detail, title: "Commit Details",
        message: "The selected commit: its message, author and changed files. Click a file to see its diff; "
            + "right-click it for Blame and File History.",
        icons: ["person.text.rectangle", "clock.arrow.circlepath"],
        prepare: { session in
            if let head = session.refs.value?.head.commit { session.selectGraph([.commit(head)]) }
        })

    private static let wipRow = TourStop(
        target: .wipRow, title: "Uncommitted Changes",
        message: "The changes you have not committed yet sit in the top row. Select it to stage and commit them.",
        prepare: { $0.selectGraph([.wip]) })

    private static let staging = TourStop(
        target: .staging, title: "Unstaged and Staged",
        message: "Stage a file with its + button, or all of them with Stage All. Staged files move to the Staged "
            + "card and go into the next commit.",
        icons: ["plus.circle"],
        prepare: { $0.selectGraph([.wip]) })

    private static func commitBox(showsAI: Bool) -> TourStop {
        TourStop(
            target: .commitBox, title: "Commit",
            message: "Write a summary, then Commit or ⌘↩. Amend changes the last commit instead."
                + (showsAI ? " Generate Message drafts one from the staged changes with your AI provider." : ""),
            icons: showsAI ? ["sparkles"] : [],
            prepare: { $0.selectGraph([.wip]) })
    }
}
