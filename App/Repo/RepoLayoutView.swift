// A repo tab's three panels (columns of cards on the page's sheet, with a small gap): the sidebar (or an open file
// history's commits, in its own wider width),
// the commit graph (or the open file's diff, or a conflicted file's conflict editor) under the operation banner while
// a merge, rebase, cherry-pick or revert is in progress, with the tab's terminal drawer under it when open, and the
// detail. The two gaps are draggable dividers; the side panels' widths are saved in `PrefKey.panelWidths`. Columns adds
// a 4th column after the detail for the open file's diff, its widths saved apart in `PrefKey.columnsWidths`.
import HistqCore
import SwiftUI

/// Sizes of the repo layout. The middle panel takes what the side panels leave. The window's minimum size
/// (`minimumWindowSize(tabPosition:preset:)`) fits the three panels at their minimums, and the vertical tabs when they
/// show.
enum RepoLayoutMetrics {
    /// Between two panels: the divider's grab area.
    static let gap: CGFloat = 8
    /// From the page sheet's edges to the cards, and from the window's edges to the sheet.
    static let inset: CGFloat = 8
    static let sidebar: ClosedRange<CGFloat> = 200...420
    /// Panel 1 while a file history shows: its commit list, wider than the sidebar by default (`historyDefault`).
    static let history: ClosedRange<CGFloat> = 200...720
    static let historyDefault: CGFloat = 400
    static let detail: ClosedRange<CGFloat> = 320...640
    static let graphMin: CGFloat = 360
    /// Stacked: the graph above the bottom pane keeps its column titles and about three rows.
    static let stackedGraphMin: CGFloat = 120
    /// Stacked: the bottom pane keeps its header card and the first lines of a diff. At the 520 pt window minimum
    /// panel 2 has about 407 pt; with the terminal drawer at its minimum (130 + its 8 pt handle), the graph, the 8 pt
    /// divider and the bottom pane take 248 of the 269 left.
    static let bottomPaneMin: CGFloat = 120
    /// Columns: column 4, the open file's diff, keeps its controls row and some code. No maximum: it takes what the
    /// graph's minimum leaves.
    static let diffColumnMin: CGFloat = 400
    /// The panels' row in the sheet: both insets and both gaps (Columns adds a third gap before column 4).
    static let chrome: CGFloat = 2 * inset + 2 * gap
    /// 200 + 360 + 320 + 32, and the sheet's 16 from the window's edges = 928 wide; with the vertical tabs, their 150
    /// and their own leading inset (the sheet's inset is the gap after them): 1086. 520 tall: the header row and about
    /// 15 list rows. The same for Classic, Stacked and Focus: Stacked's panes fit in 520 (`bottomPaneMin`), and Focus
    /// keeps the side panels' room so leaving it for Classic or Stacked never grows the window. Columns adds column 4
    /// and its gap: 1336, or 1494 with the vertical tabs (leaving Focus for Columns can grow the window).
    static func minimumWindowSize(tabPosition: TabPosition, preset: LayoutPreset) -> CGSize {
        let tabs = tabPosition == .left ? VerticalTabsMetrics.width + inset : 0
        let diffColumn = preset == .columns ? gap + diffColumnMin : 0
        return CGSize(width: sidebar.lowerBound + graphMin + detail.lowerBound + chrome + 2 * inset + tabs + diffColumn,
                      height: 520)
    }
    /// The sidebar's default keeps its tab picker's titles beside the icons.
    fileprivate static let defaults = PanelWidths(sidebar: 252, detail: 360)
}

/// The side panels' widths, stored as "sidebar,detail" in `PrefKey.panelWidths`.
private struct PanelWidths: Equatable {
    var sidebar: CGFloat
    var detail: CGFloat

    init(sidebar: CGFloat, detail: CGFloat) {
        self.sidebar = sidebar
        self.detail = detail
    }

    /// Decodes the stored value; the defaults when empty or malformed.
    init(encoded: String) {
        let values = encoded.split(separator: ",").compactMap { Double($0) }
        self = values.count == 2 ? PanelWidths(sidebar: values[0], detail: values[1]) : RepoLayoutMetrics.defaults
    }

    var encoded: String { "\(Int(sidebar.rounded())),\(Int(detail.rounded()))" }

    /// Clamped to their ranges (`sidebarRange`: panel 1's, the sidebar's or the file history's), then fitted in
    /// `available` (the width of the three panels) so the middle panel keeps `graphMin`: the side panels give up their
    /// width above their minimums in proportion to it. Below the sum of the minimums (a screen smaller than the
    /// window's minimum), all three shrink in proportion to them.
    func fitted(in available: CGFloat, sidebarRange: ClosedRange<CGFloat> = RepoLayoutMetrics.sidebar) -> PanelWidths {
        let sidebar = sidebar.clamped(to: sidebarRange)
        let detail = detail.clamped(to: RepoLayoutMetrics.detail)
        let overflow = sidebar + detail + RepoLayoutMetrics.graphMin - available
        guard overflow > 0 else { return PanelWidths(sidebar: sidebar, detail: detail) }
        let sidebarSpare = sidebar - sidebarRange.lowerBound
        let detailSpare = detail - RepoLayoutMetrics.detail.lowerBound
        let spare = sidebarSpare + detailSpare
        if overflow <= spare {
            return PanelWidths(sidebar: sidebar - overflow * sidebarSpare / spare,
                               detail: detail - overflow * detailSpare / spare)
        }
        let minimums = sidebarRange.lowerBound + RepoLayoutMetrics.detail.lowerBound + RepoLayoutMetrics.graphMin
        let scale = max(available, 0) / minimums
        return PanelWidths(sidebar: sidebarRange.lowerBound * scale,
                           detail: RepoLayoutMetrics.detail.lowerBound * scale)
    }
}

/// Columns' widths, stored as "sidebar,detail,diff" in `PrefKey.columnsWidths`, apart from the other presets'
/// `PanelWidths`. A diff of 0 (the default) shares the width the side panels leave half and half with the graph.
private struct ColumnsWidths: Equatable {
    var sidebar: CGFloat
    var detail: CGFloat
    var diff: CGFloat

    init(sidebar: CGFloat, detail: CGFloat, diff: CGFloat) {
        self.sidebar = sidebar
        self.detail = detail
        self.diff = diff
    }

    /// Decodes the stored value; the defaults when empty or malformed.
    init(encoded: String) {
        let values = encoded.split(separator: ",").compactMap { Double($0) }
        self = values.count == 3
            ? ColumnsWidths(sidebar: values[0], detail: values[1], diff: values[2])
            : ColumnsWidths(sidebar: RepoLayoutMetrics.defaults.sidebar, detail: RepoLayoutMetrics.defaults.detail,
                            diff: 0)
    }

    var encoded: String { "\(Int(sidebar.rounded())),\(Int(detail.rounded())),\(Int(diff.rounded()))" }

    /// The sidebar's and the detail's widths, for the panels Columns shares with Classic.
    var panels: PanelWidths { PanelWidths(sidebar: sidebar, detail: detail) }

    /// As `PanelWidths.fitted(in:sidebarRange:)`, with column 4: `available` is the width of the four columns, the
    /// graph keeps `graphMin`, and the other three give up their width above their minimums in proportion to it.
    func fitted(in available: CGFloat, sidebarRange: ClosedRange<CGFloat> = RepoLayoutMetrics.sidebar) -> ColumnsWidths {
        let sidebar = sidebar.clamped(to: sidebarRange)
        let detail = detail.clamped(to: RepoLayoutMetrics.detail)
        let diffMin = RepoLayoutMetrics.diffColumnMin
        let diff = Swift.max(diff > 0 ? diff : (available - sidebar - detail) / 2, diffMin)
        let overflow = sidebar + detail + diff + RepoLayoutMetrics.graphMin - available
        guard overflow > 0 else { return ColumnsWidths(sidebar: sidebar, detail: detail, diff: diff) }
        let sidebarSpare = sidebar - sidebarRange.lowerBound
        let detailSpare = detail - RepoLayoutMetrics.detail.lowerBound
        let diffSpare = diff - diffMin
        let spare = sidebarSpare + detailSpare + diffSpare
        if overflow <= spare {
            return ColumnsWidths(sidebar: sidebar - overflow * sidebarSpare / spare,
                                 detail: detail - overflow * detailSpare / spare,
                                 diff: diff - overflow * diffSpare / spare)
        }
        let minimums = sidebarRange.lowerBound + RepoLayoutMetrics.detail.lowerBound + diffMin
            + RepoLayoutMetrics.graphMin
        let scale = Swift.max(available, 0) / minimums
        return ColumnsWidths(sidebar: sidebarRange.lowerBound * scale,
                             detail: RepoLayoutMetrics.detail.lowerBound * scale, diff: diffMin * scale)
    }
}

private extension CGFloat {
    func clamped(to range: ClosedRange<CGFloat>) -> CGFloat { Swift.min(Swift.max(self, range.lowerBound), range.upperBound) }
}

/// A repo tab: sidebar | commit list | detail (a failed operation shows in its toast). Each
/// panel waits for its own data (the refs, the log, the selected detail) and shows its placeholder until then; a tab
/// switch shows the detail's placeholder in the same frame.
struct RepoLayoutView: View {
    let session: RepoSession
    @AppStorage(PrefKey.panelWidths.rawValue, store: Preferences.defaults) private var storedWidths = ""
    /// Panel 1's width while a file history shows; 0 = `RepoLayoutMetrics.historyDefault`.
    @AppStorage(PrefKey.historyPanelWidth.rawValue, store: Preferences.defaults) private var historyWidth = 0.0
    /// The widths while a divider is dragged; written to `storedWidths` when the drag ends.
    @State private var dragWidths: PanelWidths?
    /// The widths when the drag began.
    @State private var dragStart: PanelWidths?
    /// The height panel 2 gives the graph and the terminal drawer, below its banners: what bounds the drawer, so an
    /// error or operation banner never pushes the graph under its minimum. Nil until first measured.
    @State private var graphAndDrawerHeight: CGFloat?
    @AppStorage(PrefKey.layoutPreset.rawValue, store: Preferences.defaults) private var storedPreset = "classic"
    /// Stacked: the graph's share of panel 2's height above the bottom pane.
    @AppStorage(PrefKey.stackedSplit.rawValue, store: Preferences.defaults) private var stackedSplit = 0.45
    /// Stacked: the graph's height while the divider above the bottom pane is dragged; the split is written to
    /// `stackedSplit` when the drag ends.
    @State private var dragGraphHeight: CGFloat?
    /// The graph's height when that drag began.
    @State private var splitDragStart: CGFloat?
    /// The toolbar's sidebar and detail toggles (`HeaderToolbar`).
    @AppStorage(PrefKey.showSidebar.rawValue, store: Preferences.defaults) private var sidebarShown = true
    @AppStorage(PrefKey.showDetail.rawValue, store: Preferences.defaults) private var detailShown = true
    /// Columns' widths, apart from `storedWidths`.
    @AppStorage(PrefKey.columnsWidths.rawValue, store: Preferences.defaults) private var storedColumnsWidths = ""
    /// The app-wide text size, for the layout's panels (`EnvironmentValues.textSize`).
    @AppStorage(PrefKey.textSize.rawValue, store: Preferences.defaults) private var textSize = TextSize.regular
    /// Columns: the widths while a divider is dragged, written to `storedColumnsWidths` when the drag ends.
    @State private var columnsDrag: ColumnsWidths?
    /// Columns: the widths when that drag began.
    @State private var columnsDragStart: ColumnsWidths?

    private enum DividerSide { case sidebar, detail, diff }

    private var isStacked: Bool { LayoutPreset.resolved(storedPreset) == .stacked }

    /// Columns: the open file's diff shows in column 4 after the detail, and the graph stays in view.
    private var isColumns: Bool { LayoutPreset.resolved(storedPreset) == .columns }

    /// Columns: the tool panel 2 shows over the graph: the open blame or reflog, or the one the diff in column 4 was
    /// opened from (it stays in view beside its diff). A file history lists its commits in panel 1 and shows its diff,
    /// or the diff's skeleton, in column 4, so it leaves the graph in view.
    private var columnsTool: RepoTool? {
        switch session.openTool ?? session.returnTool {
        case .fileHistory?, nil: nil
        case let tool?: tool
        }
    }

    /// Focus: the sidebar and the detail (with their dividers) leave the tree and panel 2 takes the whole row. The
    /// stored widths are neither used nor written, so leaving Focus shows the panels as they were.
    private var isFocus: Bool { LayoutPreset.resolved(storedPreset) == .focus }

    /// An open pull request over the graph (Classic, Focus, Columns) hides the detail and its divider (Columns: column
    /// 4 too): the pull request page has its own side column, and the detail of a commit no longer in view only takes
    /// its room. Stacked keeps the detail, since the graph stays on top there.
    private var showsDetail: Bool {
        detailShown && !Self.hidesDetail(session: session, preset: LayoutPreset.resolved(storedPreset))
    }

    /// The detail is hidden whatever its toggle says (`showsDetail`): Focus, or an open pull request outside Stacked.
    /// The toolbar's detail toggle is off then. It reads `openHosted` on every path, Focus included, so the toolbar's
    /// observation tracks it and wakes when a pull request opens or closes.
    static func hidesDetail(session: RepoSession, preset: LayoutPreset) -> Bool {
        var isPullRequest = false
        if case .pullRequest = session.openHosted { isPullRequest = true }
        return preset == .focus || (isPullRequest && preset != .stacked)
    }

    /// Stacked shows a file, pull request, issue or tool in its bottom pane.
    private var isStackedPaneOpen: Bool {
        isStacked && (session.openFile != nil || session.openHosted != nil || session.openTool != nil)
    }

    var body: some View {
        GeometryReader { proxy in
            let available = proxy.size.width - RepoLayoutMetrics.chrome - (isColumns ? RepoLayoutMetrics.gap : 0)
            let columns = isColumns
                ? (columnsDrag ?? savedColumnsWidths).fitted(in: available, sidebarRange: panel1Range) : nil
            let widths = columns?.panels ?? (dragWidths ?? savedWidths).fitted(in: available, sidebarRange: panel1Range)
            VStack(spacing: SectionCardMetrics.spacing) {
                panels(widths: widths, columns: columns, available: available, height: proxy.size.height)
            }
            .padding(RepoLayoutMetrics.inset)
        }
        .environment(\.textSize, textSize)
        // The tab's GitHub lists, for the PRs tab and the graph's PR badges.
        .background(GitHubDriver(session: session))
    }

    /// Panel 1's width range: the sidebar's, or the file history's (wider).
    private var panel1Range: ClosedRange<CGFloat> {
        session.historyTool == nil ? RepoLayoutMetrics.sidebar : RepoLayoutMetrics.history
    }

    /// The saved widths; panel 1's is the file history's own while one shows.
    private var savedWidths: PanelWidths {
        var widths = PanelWidths(encoded: storedWidths)
        if session.historyTool != nil {
            widths.sidebar = historyWidth > 0 ? historyWidth : RepoLayoutMetrics.historyDefault
        }
        return widths
    }

    /// Columns' saved widths; panel 1's is the file history's own while one shows, as in `savedWidths`.
    private var savedColumnsWidths: ColumnsWidths {
        var widths = ColumnsWidths(encoded: storedColumnsWidths)
        if session.historyTool != nil {
            widths.sidebar = historyWidth > 0 ? historyWidth : RepoLayoutMetrics.historyDefault
        }
        return widths
    }

    /// The three panels and their dividers (Focus: panel 2 alone; an open pull request: no detail; the toolbar's
    /// toggles hide the sidebar or the detail), and Columns' column 4 (`columns`: its widths; nil in the other
    /// presets). A file history takes panel 1 with its commits, whatever the preset and the sidebar toggle say.
    /// `height`: the layout's, which bounds the terminal drawer until panel 2's own height is measured.
    private func panels(widths: PanelWidths, columns: ColumnsWidths?, available: CGFloat, height: CGFloat) -> some View {
        let history = session.historyTool
        // A blame leaves panel 1 out so its lines get the width (user, 2026-11-18); in Columns also while a diff opened
        // from it shows in column 4, the blame still in view.
        let blameOpen = if case .blame? = (isColumns ? columnsTool : session.openTool) { true } else { false }
        let sidebarVisible = !isFocus && sidebarShown && !blameOpen
        return HStack(spacing: 0) {
            // The panels' cards sit right on the page's sheet (MainView), a level between the window glass and
            // the cards.
            if sidebarVisible || history != nil {
                ZStack {
                    // The sidebar stays mounted under a file history, so closing it shows the sidebar as it was.
                    if sidebarVisible {
                        SidebarView(session: session)
                            .opacity(history == nil ? 1 : 0)
                            .allowsHitTesting(history == nil)
                            .accessibilityHidden(history != nil)
                    }
                    if let history {
                        FileHistoryView(session: session, tool: history)
                    }
                }
                .frame(width: widths.sidebar)
                divider(.sidebar, widths: widths, columns: columns, available: available)
            }
            VStack(spacing: SectionCardMetrics.spacing) {
                // Reads the operation itself, so a status read redraws the banner and not the panels.
                OperationBanner(session: session)
                VStack(spacing: 0) {
                    panel2
                    // The tab's terminal under the graph (and under an open file); its handle is the gap above
                    // it. Without a terminal yet (shown with a new tab) it shows its placeholder.
                    if session.isTerminalOpen {
                        TerminalDrawer(
                            session: session, terminal: session.terminal,
                            available: graphAndDrawerHeight ?? height, stackedPaneOpen: isStackedPaneOpen)
                    }
                }
                .onGeometryChange(for: CGFloat.self) { $0.size.height } action: { graphAndDrawerHeight = $0 }
            }
            .frame(maxWidth: .infinity)
            if showsDetail {
                divider(.detail, widths: widths, columns: columns, available: available)
                DetailPanel(session: session)
                    .frame(width: widths.detail)
            }
            // Column 4 shows whatever the detail toggle says, so a diff always has its place; an open pull request
            // hides it with the detail.
            if let columns, !Self.hidesDetail(session: session, preset: .columns) {
                divider(.diff, widths: widths, columns: columns, available: available)
                diffColumn
                    .frame(width: columns.diff)
            }
        }
    }

    /// Columns' column 4: the open file's diff (a conflict opens its editor over panel 2), a file history's diff
    /// skeleton until its first diff opens, else an empty card, so opening a file never shifts the layout.
    @ViewBuilder private var diffColumn: some View {
        if let target = session.openFile, !target.isConflict {
            DiffView(session: session, target: target)
        } else if case .fileHistory(let path, _, _)? = session.openTool {
            FileHistoryDiffPlaceholder(session: session, path: path)
        } else {
            DiffNoticeCard(title: "Diff", systemImage: "doc.text", message: "Select a file to see its changes")
        }
    }

    /// The graph, with the open file's diff or conflict editor, the open pull request or issue, or the open blame or
    /// reflog over it (Classic and Focus), or under it in a bottom pane (Stacked). A file history lists its commits in
    /// panel 1; panel 2 shows the diff of the selected one.
    @ViewBuilder private var panel2: some View {
        if isStacked {
            stackedPanel2
        } else {
            classicPanel2
        }
    }

    private var classicPanel2: some View {
        ZStack {
            // The graph stays mounted under an open file, so Esc brings it back as it was (scroll, selection)
            // and opening a file costs no teardown in the click's frame.
            // Columns: the plain diff and a file history show in column 4, beside the graph.
            let fileOpen = isColumns
                ? session.openFile?.isConflict == true || session.openHosted != nil || columnsTool != nil
                : session.openFile != nil || session.openHosted != nil || session.openTool != nil
            CommitListPanel(session: session)
                .opacity(fileOpen ? 0 : 1)
                .allowsHitTesting(!fileOpen)
                .accessibilityHidden(fileOpen)
            panel2Overlays
        }
    }

    /// Stacked: the graph stays on top and clickable; what Classic shows over it shows in a pane under a divider, only
    /// while one is open. The graph keeps its place in the tree, so opening or closing the pane never rebuilds it, and
    /// another file swaps in the pane in place.
    private var stackedPanel2: some View {
        let paneOpen = isStackedPaneOpen
        return GeometryReader { proxy in
            let graphHeight = stackedGraphHeight(in: proxy.size.height)
            VStack(spacing: 0) {
                CommitListPanel(session: session)
                    .frame(height: paneOpen ? graphHeight : nil)
                if paneOpen {
                    splitDivider(graphHeight: graphHeight, height: proxy.size.height)
                    // A conflict editor taller than the pane's minimum is cut, never drawn over the drawer.
                    ZStack { panel2Overlays }
                        .frame(minHeight: 0, maxHeight: .infinity)
                        .clipped()
                }
            }
        }
    }

    /// Stacked: the graph's height in panel 2's `height`, from the split or the drag, keeping the bottom pane's
    /// minimum, then the graph's.
    private func stackedGraphHeight(in height: CGFloat) -> CGFloat {
        let room = height - RepoLayoutMetrics.gap
        let wanted = dragGraphHeight ?? room * min(max(stackedSplit, 0), 1)
        return max(RepoLayoutMetrics.stackedGraphMin, min(wanted, room - RepoLayoutMetrics.bottomPaneMin))
    }

    /// Stacked: the gap between the graph and the bottom pane (as the terminal drawer's handle): drag it to share
    /// panel 2's height.
    private func splitDivider(graphHeight: CGFloat, height: CGFloat) -> some View {
        Color.clear
            .frame(height: RepoLayoutMetrics.gap)
            .frame(maxWidth: .infinity)
            .contentShape(Rectangle())
            .pointerStyle(.rowResize)
            .gesture(
                DragGesture(minimumDistance: 1, coordinateSpace: .global)
                    .onChanged { drag in
                        let start = splitDragStart ?? graphHeight
                        if splitDragStart == nil { splitDragStart = graphHeight }
                        // Down makes the graph taller.
                        dragGraphHeight = start + drag.translation.height
                    }
                    .onEnded { _ in
                        let room = height - RepoLayoutMetrics.gap
                        if room > 0 { stackedSplit = stackedGraphHeight(in: height) / room }
                        dragGraphHeight = nil
                        splitDragStart = nil
                    })
            .accessibilityHidden(true)
    }

    /// What shows in panel 2 instead of the graph: the open blame or reflog (a file history's skeleton until its diff
    /// opens), pull request or issue, or file. Columns leaves out the plain diff and the file history (column 4), and
    /// keeps a blame or reflog in view beside the diff opened from it.
    @ViewBuilder private var panel2Overlays: some View {
        // A tool stays mounted under the diff opened from it, so Back brings it back as it was (scroll).
        if let tool = session.openTool ?? session.returnTool {
            let toolHidden = isColumns ? columnsTool == nil : session.openTool == nil
            Group {
                switch tool {
                case .fileHistory(let path, _, _):
                    // Panel 1 lists the commits; until a commit's diff opens, panel 2 holds its skeleton.
                    if !toolHidden { FileHistoryDiffPlaceholder(session: session, path: path) }
                case .blame(let path, let rev):
                    BlameView(session: session, path: path, rev: rev)
                case .reflog:
                    ReflogView(session: session)
                }
            }
            .opacity(toolHidden ? 0 : 1)
            .allowsHitTesting(!toolHidden)
            .accessibilityHidden(toolHidden)
            // Its Back button's Esc must not compete with the diff's.
            .disabled(toolHidden)
        }
        if case .pullRequest(let number) = session.openHosted {
            PRDetailView(session: session, number: number)
        } else if case .issue(let number) = session.openHosted {
            IssueDetailView(session: session, number: number)
        } else if let target = session.openFile {
            if target.isConflict {
                ConflictEditorView(session: session, target: target)
            } else if !isColumns {
                DiffView(session: session, target: target)
            }
        }
    }

    /// The gap between two panels: drag it to resize the side panel next to it. Columns (`columns` set) resizes and
    /// saves its own widths (`dragColumns`), never `storedWidths`.
    private func divider(_ side: DividerSide, widths: PanelWidths, columns: ColumnsWidths?,
                         available: CGFloat) -> some View {
        Color.clear
            .frame(width: RepoLayoutMetrics.gap)
            .frame(maxHeight: .infinity)
            .contentShape(Rectangle())
            .pointerStyle(.columnResize)
            .gesture(
                DragGesture(minimumDistance: 1, coordinateSpace: .global)
                    .onChanged { drag in
                        if let columns {
                            dragColumns(side, from: columns, by: drag.translation.width, available: available)
                            return
                        }
                        let start = dragStart ?? widths
                        if dragStart == nil { dragStart = widths }
                        var next = start
                        switch side {
                        case .sidebar:
                            let limit = available - start.detail - RepoLayoutMetrics.graphMin
                            next.sidebar = min(start.sidebar + drag.translation.width, limit)
                                .clamped(to: panel1Range)
                        case .detail:
                            let limit = available - start.sidebar - RepoLayoutMetrics.graphMin
                            next.detail = min(start.detail - drag.translation.width, limit)
                                .clamped(to: RepoLayoutMetrics.detail)
                        case .diff:
                            break
                        }
                        dragWidths = next
                    }
                    .onEnded { _ in
                        if let columnsDrag { saveColumns(columnsDrag) }
                        if let dragWidths {
                            // A file history keeps its own panel 1 width; the sidebar's stays as it was.
                            if session.historyTool != nil {
                                historyWidth = dragWidths.sidebar
                                storedWidths = PanelWidths(
                                    sidebar: PanelWidths(encoded: storedWidths).sidebar, detail: dragWidths.detail).encoded
                            } else {
                                storedWidths = dragWidths.encoded
                            }
                        }
                        dragWidths = nil
                        dragStart = nil
                        columnsDrag = nil
                        columnsDragStart = nil
                    })
            .accessibilityHidden(true)
    }

    /// Columns: the widths while `side`'s divider is dragged `dx` from where it began; the graph keeps `graphMin`, and
    /// column 4 has no maximum (left widens it).
    private func dragColumns(_ side: DividerSide, from columns: ColumnsWidths, by dx: CGFloat, available: CGFloat) {
        let start = columnsDragStart ?? columns
        if columnsDragStart == nil { columnsDragStart = columns }
        let graphMin = RepoLayoutMetrics.graphMin
        var next = start
        switch side {
        case .sidebar:
            next.sidebar = min(start.sidebar + dx, available - start.detail - start.diff - graphMin)
                .clamped(to: panel1Range)
        case .detail:
            next.detail = min(start.detail - dx, available - start.sidebar - start.diff - graphMin)
                .clamped(to: RepoLayoutMetrics.detail)
        case .diff:
            next.diff = max(min(start.diff - dx, available - start.sidebar - start.detail - graphMin),
                            RepoLayoutMetrics.diffColumnMin)
        }
        columnsDrag = next
    }

    /// Columns: a drag's widths into `storedColumnsWidths`. A file history keeps its own panel 1 width, as in Classic.
    private func saveColumns(_ widths: ColumnsWidths) {
        var stored = widths
        if session.historyTool != nil {
            historyWidth = widths.sidebar
            stored.sidebar = ColumnsWidths(encoded: storedColumnsWidths).sidebar
        }
        storedColumnsWidths = stored.encoded
    }
}

// MARK: - Panel 2: the commit graph

/// The commit graph in one card without a title row: the graph's column titles are its header. Skeleton rows (under a
/// skeleton header) while the first page loads, then `GraphView` with every row (the WIP and stash rows above the
/// commits).
private struct CommitListPanel: View {
    let session: RepoSession
    @AppStorage(PrefKey.dateFormat.rawValue, store: Preferences.defaults) private var dateFormat = "MM/dd/yy @ HH:mm"
    @AppStorage(PrefKey.rowDensity.rawValue, store: Preferences.defaults) private var rowDensity = "regular"
    @AppStorage(PrefKey.textSize.rawValue, store: Preferences.defaults) private var textSize = TextSize.regular
    @AppStorage(PrefKey.graphShowMessage.rawValue, store: Preferences.defaults) private var showMessage = true
    @AppStorage(PrefKey.graphShowAuthor.rawValue, store: Preferences.defaults) private var showAuthor = true
    @AppStorage(PrefKey.graphShowDate.rawValue, store: Preferences.defaults) private var showDate = true
    @AppStorage(PrefKey.graphFadeOtherWorktrees.rawValue, store: Preferences.defaults) private var fadesWorktrees = true

    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        SectionCard(nil, contentPadding: 0) {
            // ⌘F (Edit › Find…): the search bar slides up from the card's bottom edge over the graph, which neither
            // moves nor resizes (it keeps its identity).
            graph
                .overlay(alignment: .topTrailing) { GraphVisibilityChip(session: session) }
                .overlay(alignment: .bottom) {
                    if session.graphSearch.isOpen {
                        GraphSearchBar(search: session.graphSearch)
                            .transition(reduceMotion ? .opacity : .move(edge: .bottom).combined(with: .opacity))
                    }
                }
                .clipShape(RoundedRectangle(cornerRadius: SettingsMetrics.cardRadius, style: .continuous))
                .animation(reduceMotion ? nil : Motion.sheet, value: session.graphSearch.isOpen)
        }
    }

    private var graph: some View {
        Group {
            switch session.log {
            case .idle, .loading:
                SkeletonCommitRows(textSize: textSize, dateFormat: dateFormat, hiddenColumns: hiddenColumns)
                    .allowsHitTesting(false)
                    .accessibilityElement(children: .ignore)
                    .accessibilityLabel("Loading")
            case .loaded(let log):
                // A click selects through the session (the detail switches in the same frame); a double-click
                // checks out (on a badge, that badge's ref); a right-click opens the row's menu, or on a badge the badge's ref menu followed by its
                // commit's; a badge dropped on another opens
                // Merge / Rebase / Fast-forward / Create Pull Request; a click on a badge's "#N" chip opens that
                // pull request in the same frame.
                GraphView(log: log, refs: session.visibleRefs, status: session.status.value,
                          dateFormat: dateFormat, rowDensity: rowDensity, textSize: textSize,
                          selection: session.graphSelection,
                          onSelect: { [session] items in session.selectGraph(items) },
                          onActivate: { [session] item, badge in
                              if let ref = badge?.sidebarItem { return RepoMenus.checkout(ref, session) }
                              RepoMenus.activate(item, session: session)
                          },
                          menuEntries: { [session] item, badge in
                              if let ref = badge?.sidebarItem { return RepoMenus.badge(ref, on: item, session: session) }
                              return RepoMenus.entries(for: item, session: session)
                          },
                          dropEntries: { [session] source, target in
                              guard let source = source.sidebarItem, let target = target.sidebarItem else { return [] }
                              return RepoMenus.drop(source, onto: target, session)
                          },
                          canUndo: { [session] redo in session.historyAvailability(redo: redo).isEnabled },
                          onUndo: { [session] redo in if redo { session.redo() } else { session.undo() } },
                          pullRequests: session.github.branchPullRequests,
                          remotes: session.remotes.map(\.name),
                          remoteURLs: Dictionary(session.remotes.map { ($0.name, $0.url) },
                                                 uniquingKeysWith: { first, _ in first }),
                          onOpenPullRequest: { [session] number in session.selectHosted(.pullRequest(number)) },
                          branchMap: session.branchMap,
                          // Off: an empty map fades no commit (another worktree's WIP row still fades).
                          worktreeMap: fadesWorktrees ? session.worktreeMap : WorktreeMap(),
                          dimming: session.graphSearch.dimming,
                          revealToken: session.graphSearch.revealToken,
                          bottomInset: session.graphSearch.isOpen ? GraphSearchBar.overlayHeight : 0,
                          onTable: { [search = session.graphSearch] table in search.table = table },
                          hiddenColumns: hiddenColumns,
                          onEscape: { [search = session.graphSearch] in
                              guard search.isOpen else { return false }
                              search.close()
                              return true
                          },
                          scrollPosition: session.graphScroll,
                          onScroll: { [session] position in session.graphScroll = position })
                    .onAppear { UITiming.content("commits \(session.url.lastPathComponent)") }
            case .failed(let message):
                Label(message, systemImage: "exclamationmark.triangle")
                    .foregroundStyle(.secondary)
                    .padding(12)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
    }

    /// The text columns Settings › Appearance hides.
    private var hiddenColumns: Set<GraphColumn> {
        var hidden: Set<GraphColumn> = []
        if !showMessage { hidden.insert(.message) }
        if !showAuthor { hidden.insert(.author) }
        if !showDate { hidden.insert(.date) }
        return hidden
    }
}

/// The graph's shape while the log loads: the real column titles (static, so no skeleton) and a hairline, then rows
/// of node, subject (varied widths), author and date.
private struct SkeletonCommitRows: View {
    let textSize: TextSize
    let dateFormat: String
    let hiddenColumns: Set<GraphColumn>
    private static let subjects: [CGFloat] = [0.7, 0.5, 0.82, 0.62, 0.45, 0.75, 0.58, 0.66, 0.4, 0.72]

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            GraphHeaderPlaceholder(textSize: textSize, dateFormat: dateFormat, hiddenColumns: hiddenColumns)
            ForEach(Self.subjects.indices, id: \.self) { index in
                HStack(spacing: 8) {
                    SkeletonLine(width: 16, height: 16)
                        .frame(width: 24)
                    SkeletonLine(fraction: Self.subjects[index], height: 11)
                    SkeletonLine(width: index.isMultiple(of: 3) ? 64 : 84, height: 11)
                    SkeletonLine(width: 96, height: 11)
                }
                .padding(.horizontal, 12)
                .frame(height: 32)
            }
        }
    }
}

/// The graph's column titles while the log loads, drawn as `GraphHeaderView` draws them (same widths, font and
/// hairlines), so the header does not change when the table replaces it.
private struct GraphHeaderPlaceholder: View {
    let textSize: TextSize
    let dateFormat: String
    let hiddenColumns: Set<GraphColumn>
    @AppStorage(PrefKey.graphColumnWidths.rawValue, store: Preferences.defaults) private var storedWidths = ""

    var body: some View {
        let stored = GraphColumn.storedWidths(storedWidths)
        let visible = GraphColumn.allCases.filter { !hiddenColumns.contains($0) }
        // The table's fill column: the message, or the last visible column when the message is hidden.
        let fill = visible.contains(.message) ? GraphColumn.message : visible.last
        HStack(spacing: 0) {
            ForEach(visible, id: \.self) { column in
                let width = stored[column] ?? column.defaultWidth(textSize: textSize, dateFormat: dateFormat)
                title(column, width: width)
                    .frame(minWidth: column == fill ? column.minWidth : width,
                           maxWidth: column == fill ? .infinity : width, maxHeight: .infinity, alignment: .leading)
                    .overlay(alignment: .trailing) {
                        Rectangle().fill(Color(nsColor: .separatorColor)).frame(width: 1).padding(.vertical, 6)
                    }
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .frame(height: 26)
        .clipped()
        .overlay(alignment: .bottom) { Rectangle().fill(Color(nsColor: .separatorColor)).frame(height: 1) }
    }

    @ViewBuilder private func title(_ column: GraphColumn, width: CGFloat) -> some View {
        if let symbol = column.compactSymbol, !GraphHeaderCell.fits(column.title, width: width, textSize: textSize) {
            Image(systemName: symbol)
                .font(.system(size: 11, weight: .semibold))
                .foregroundStyle(.secondary)
                .padding(.leading, 8)
        } else {
            Text(column.title.uppercased())
                .font(.system(size: textSize.scaled(10.5), weight: .semibold))
                .kerning(0.6)
                .foregroundStyle(.secondary)
                .lineLimit(1)
                .padding(.leading, 8)
                .padding(.trailing, 4)
        }
    }
}

// MARK: - Panel 3: the detail

/// The selected detail, its parts in cards: the WIP panel, a commit or stash, a multi-selection, a compare, or
/// the overview cards (an unborn branch). Until it loads, the selection's cards hold skeleton rows (`PlaceholderCard`:
/// spinner after 150 ms, the `placeholder` line); then the `content` line. A commit of the log skips the placeholder:
/// its header shows in the click's frame (`content-info`), its files once read (`content`). All carry
/// `session.selectDetail`.
private struct DetailPanel: View {
    let session: RepoSession
    @Environment(WindowModel.self) private var model

    /// A select's content is on screen once its detail is ready (a commit's files read).
    private struct ContentKey: Equatable {
        let token: Int
        let isReady: Bool
    }

    var body: some View {
        VStack(spacing: SectionCardMetrics.spacing) {
            // Reads the status itself, so a status read redraws the notice and not the detail.
            WorkingChangesNotice(session: session)
            content
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .coordinateSpace(.named(FilesLayoutLog.coordinateSpace))
    }

    @ViewBuilder private var content: some View {
        Group {
            switch session.detail {
            case .idle, .loading:
                PlaceholderCard(
                    token: session.selectToken, detail: session.selectDetail,
                    isCurrent: { [model, session] in model.selectedSession === session }
                ) {
                    placeholder
                }
            case .loaded(let detail):
                // Keyed on the select, not on appearing: a switch between two loaded commits can keep this view. A
                // commit's header shows before its files: `content` waits for them (`content-info` is the header's).
                loaded(detail)
                    .onChange(of: ContentKey(token: session.selectToken, isReady: detail.isReady), initial: true) {
                        _, key in
                        if key.isReady { UITiming.content(session.selectDetail) }
                    }
            case .failed(let message):
                FailedCard(message: message, path: session.url.path)
                    .onChange(of: session.selectToken, initial: true) {
                        UITiming.content("\(session.selectDetail) failed")
                    }
            }
        }
    }

    /// The loading selection's cards. A tab that just opened shows the WIP's while its status is unknown or dirty.
    @ViewBuilder private var placeholder: some View {
        switch session.selection {
        case .wip:
            WIPPlaceholder(hasConflicts: hasConflicts)
        case .commit, .stash, .ref:
            CommitDetailPlaceholder(token: session.selectToken, detail: session.selectDetail)
        case .multiple:
            // The rows and whether they make a diff are known now: only the files wait for the load.
            MultipleSelectionPanel(session: session, items: session.graphSelection,
                                   diff: RepoMenus.combinedDiff(session), files: nil, token: session.selectToken,
                                   timingDetail: session.selectDetail)
        case .worktree(let path):
            WorktreeChangesPlaceholder(path: path)
        case .submodule(let path):
            SubmoduleStatusPanel(session: session, path: path, detail: nil)
        case .compare(let base, let head):
            CompareDetailPanel(session: session, base: base, head: head, files: nil, token: session.selectToken,
                               timingDetail: session.selectDetail)
        case .overview:
            if session.status.value?.entries.isEmpty == true {
                CommitDetailPlaceholder(token: session.selectToken, detail: session.selectDetail)
            } else {
                WIPPlaceholder(hasConflicts: hasConflicts)
            }
        }
    }

    /// The last status had conflicted files: the WIP placeholder keeps the Conflicted card's place.
    private var hasConflicts: Bool {
        session.status.value?.conflicted.isEmpty == false
    }

    @ViewBuilder private func loaded(_ detail: RepoSession.Detail) -> some View {
        switch detail {
        case .wip:
            WIPPanel(session: session)
        case .commit(let commit):
            CommitDetailPanel(session: session, commit: commit, token: session.selectToken,
                              timingDetail: session.selectDetail)
        case .multiple(let items, let diff, let files):
            MultipleSelectionPanel(session: session, items: items, diff: diff, files: files, token: session.selectToken,
                                   timingDetail: session.selectDetail)
        case .worktree(let path, let status):
            WorktreeChangesPanel(path: path, status: status)
        case .submodule(let detail):
            SubmoduleStatusPanel(session: session, path: detail.submodule.path, detail: detail)
        case .compare(let base, let head, let files):
            CompareDetailPanel(session: session, base: base, head: head, files: files, token: session.selectToken,
                               timingDetail: session.selectDetail)
        case .overview:
            ScrollView {
                OverviewCards(branch: branch, path: session.url.path, commits: commits, status: session.status.value)
            }
        }
    }

    private var branch: String {
        switch session.refs.value?.head {
        case .branch(let name, _), .unborn(let name): name
        case .detached(let commit): "Detached at \(commit.prefix(7))"
        case nil: "—"
        }
    }

    private var commits: String {
        switch session.log {
        case .loaded(let log): "\(log.commits.count)\(log.isComplete ? "" : "+") commits on all branches"
        case .failed: "History unavailable"
        case .idle, .loading: "Counting commits…"
        }
    }
}

/// Over a commit's or a stash's detail while the working tree has changes: how many files changed and
/// a View Changes button that selects the WIP row. Nothing for the WIP itself or a clean tree.
private struct WorkingChangesNotice: View {
    let session: RepoSession

    var body: some View {
        if let count {
            let tone = Color.accentColor
            SectionCard(nil, contentPadding: 10) {
                HStack(spacing: 10) {
                    Image(systemName: "pencil.line")
                        .foregroundStyle(tone)
                        .font(.system(size: 15))
                        .accessibilityHidden(true)
                    // Two lines, so a narrow panel keeps the count whole.
                    VStack(alignment: .leading, spacing: 2) {
                        Text(count == 1 ? "1 file change" : "\(count) file changes")
                            .font(.body.weight(.semibold))
                        Text("in working directory")
                            .font(.settingsCaption)
                            .foregroundStyle(.secondary)
                    }
                    .lineLimit(1)
                    .accessibilityElement(children: .combine)
                    Spacer(minLength: 8)
                    Button("View Changes") { session.selectGraph([.wip]) }
                        .buttonStyle(RowTextButtonStyle(formRow: true, prominent: true))
                        .help("Show the working directory's changes")
                }
            }
            .modifier(NoticeTint(tone: tone))
        }
    }

    /// The changed files, for a commit or a stash (or a ref loading as its commit); nil otherwise or when clean.
    private var count: Int? {
        switch session.selection {
        case .commit, .stash, .ref: break
        case .overview, .wip, .multiple, .worktree, .compare, .submodule: return nil
        }
        guard let count = session.status.value?.entries.count, count > 0 else { return nil }
        return count
    }
}

/// The overview's cards: Branch, History, Working tree. A nil value draws its skeleton line in the same place, so
/// the placeholder has the loaded cards' footprint.
private struct OverviewCards: View {
    let branch: String?
    let path: String
    let commits: String?
    let status: WorkingStatus?

    var body: some View {
        VStack(alignment: .leading, spacing: SectionCardMetrics.spacing) {
            SectionCard("Branch", systemImage: "lucide-git-branch") {
                VStack(alignment: .leading, spacing: 4) {
                    if let branch {
                        Text(branch)
                            .font(.title3.weight(.semibold))
                            .lineLimit(1)
                            .truncationMode(.middle)
                    } else {
                        SkeletonLine(width: 96, height: 16).frame(height: 24)
                    }
                    Text(path)
                        .font(.settingsCaption)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                        .truncationMode(.middle)
                }
            }
            SectionCard("History", systemImage: "clock") {
                if let commits {
                    Text(commits).monospacedDigit()
                } else {
                    SkeletonLine(fraction: 0.6, height: 12).frame(height: 16)
                }
            }
            SectionCard("Working tree", systemImage: "doc.on.doc", count: status.map(Self.changeCount),
                        countIsLoading: status == nil) {
                VStack(alignment: .leading, spacing: 2) {
                    CountRow(title: "Staged", value: status?.staged.count, width: 0.35)
                    CountRow(title: "Unstaged", value: status?.unstaged.count, width: 0.45)
                    CountRow(title: "Untracked", value: status?.untracked.count, width: 0.4)
                    if let conflicted = status?.conflicted.count, conflicted > 0 {
                        CountRow(title: "Conflicted", value: conflicted, width: 0.4)
                    }
                }
            }
        }
    }

    private static func changeCount(_ status: WorkingStatus) -> Int {
        status.staged.count + status.unstaged.count + status.untracked.count + status.conflicted.count
    }
}

/// A title and a count; a skeleton line of `width` (a fraction of the row) while the value is nil.
private struct CountRow: View {
    let title: String
    let value: Int?
    let width: CGFloat

    var body: some View {
        HStack(spacing: 8) {
            if let value {
                Text(title)
                Spacer(minLength: 8)
                Text("\(value)")
                    .monospacedDigit()
                    .foregroundStyle(.secondary)
            } else {
                SkeletonLine(fraction: width, height: 12)
            }
        }
        .frame(height: 22)
        .accessibilityElement(children: .combine)
    }
}

/// The overview when the repo cannot be read (not a repository, git missing).
private struct FailedCard: View {
    let message: String
    let path: String

    var body: some View {
        SectionCard("Overview", systemImage: "exclamationmark.triangle") {
            VStack(alignment: .leading, spacing: 6) {
                Text(message)
                    .font(.body.weight(.medium))
                    .fixedSize(horizontal: false, vertical: true)
                Text(path)
                    .font(.settingsCaption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .truncationMode(.middle)
            }
        }
    }
}
