// The commit graph: an NSTableView with gk's columns (BRANCH / TAG, GRAPH, COMMIT MESSAGE, AUTHOR, COMMIT DATE / TIME).
// Rows: the WIP row (when the working tree has changes), a WIP row per other worktree with changes (labeled with its
// folder's name; a click opens it in a tab), the stash rows, then the commits, laid out by `GraphLayout`.
// The table only asks for the rows on screen, so its cost does not grow with the log: a later page of the same load is
// inserted as rows, a new load reloads. A click selects at once (`action`); a double-click calls the checkout hook
// (`doubleAction`) without delaying the single click. A click on a branch badge's pull request chip opens that pull
// request at mouse down instead of selecting the row.
import AppKit
import HistqCore
import SwiftUI

/// What a graph row stands for: what the selection callback and the double-click hook get.
enum GraphItem: Hashable, Sendable {
    case wip
    /// A stash, by its commit hash.
    case stash(String)
    case commit(String)
    /// Another worktree's WIP row, by the worktree's path. Never a selection: a click opens the worktree in a tab.
    case worktree(String)
}

/// The graph's columns, in gk's order. Widths are resizable and saved in `PrefKey.graphColumnWidths`; the message
/// column takes what the others leave. Settings › Appearance can hide the message, author and date columns.
enum GraphColumn: String, CaseIterable {
    case refs, graph, message, author, date

    var title: String {
        switch self {
        case .refs: "Branch / Tag"
        case .graph: "Graph"
        case .message: "Commit message"
        case .author: "Author"
        case .date: "Commit date / time"
        }
    }

    var defaultWidth: CGFloat {
        switch self {
        case .refs: 116
        // Four lanes at the regular row density.
        case .graph: GraphMetrics(density: "regular").width(lanes: 4)
        case .message: 240
        case .author: 76
        // Fits "12/31/25 @ 23:00", the default format since 7.5.
        case .date: 120
        }
    }

    var minWidth: CGFloat {
        switch self {
        case .refs: 40
        case .graph: 32
        case .message: 80
        case .author: 40
        case .date: 60
        }
    }

    var identifier: NSUserInterfaceItemIdentifier { NSUserInterfaceItemIdentifier(rawValue) }

    /// Decodes `PrefKey.graphColumnWidths` ("refs:124,graph:120,…"); unknown or malformed entries are skipped.
    static func storedWidths(_ encoded: String) -> [GraphColumn: CGFloat] {
        var widths: [GraphColumn: CGFloat] = [:]
        for entry in encoded.split(separator: ",") {
            let parts = entry.split(separator: ":")
            guard parts.count == 2, let column = GraphColumn(rawValue: String(parts[0])), let width = Double(parts[1])
            else { continue }
            widths[column] = max(column.minWidth, width)
        }
        return widths
    }
}

/// The graph table. `log` gives the rows; `refs` the badges; `status` the WIP row's counts. `dateFormat` and
/// `rowDensity` are `PrefKey.dateFormat` and `PrefKey.rowDensity`. `onSelect` gets the selected rows (in row order) as
/// soon as the selection changes (a click, ⌘/⇧-click, the arrow keys); `onActivate` gets a double-clicked row.
/// `selection` is the selection the table follows: a new one (a parent jump) is selected and scrolled to, without an
/// `onSelect` echo. ⌘Z / ⇧⌘Z while the table has the focus ask `canUndo` and run `onUndo` (`redo` true for Redo);
/// a text field keeps its own undo, since its field editor answers first.
struct GraphView: NSViewRepresentable {
    let log: LogSnapshot
    let refs: Refs?
    let status: WorkingStatus?
    let dateFormat: String
    let rowDensity: String
    var selection: [GraphItem] = []
    var onSelect: @MainActor ([GraphItem]) -> Void = { _ in }
    var onActivate: @MainActor (GraphItem) -> Void = { _ in }
    /// The context menu of a row; `badge` is the ref badge under the pointer, if any.
    var menuEntries: @MainActor (GraphItem, RefBadge?) -> [MenuEntry] = { _, _ in [] }
    /// The menu of a branch badge dropped on another (source, target).
    var dropEntries: @MainActor (RefBadge, RefBadge) -> [MenuEntry] = { _, _ in [] }
    var canUndo: @MainActor (_ redo: Bool) -> Bool = { _ in false }
    var onUndo: @MainActor (_ redo: Bool) -> Void = { _ in }
    /// A click on another worktree's WIP row, with its path (arrow keys passing over the row do not call it).
    var onOpenWorktree: @MainActor (String) -> Void = { _ in }
    /// The open pull requests by remote branch (`GitHubStore.branchPullRequests`): their chips on the branch badges.
    var pullRequests: [String: RefBadge.PullRequest] = [:]
    /// The repo's remote names (`RepoSession.remotes`): with one remote, a remote branch's badge drops the remote
    /// from its name (`RefBadge.remoteLabel`).
    var remotes: [String] = []
    /// A click on a pull request chip, with its number.
    var onOpenPullRequest: @MainActor (Int) -> Void = { _ in }
    /// The branch each commit is on (`RepoSession.branchMap`): a lone selected commit without a branch badge of its own
    /// shows its branch's badge faded.
    var branchMap = BranchMap()
    /// The rows the graph search dims (`GraphSearch.dimming`).
    var dimming = GraphDimming()
    /// New with each move to a search match: the selected row is centred when it is off screen.
    var revealToken = 0
    /// The table, once made (the search gives it the focus back when it closes).
    var onTable: @MainActor (NSTableView) -> Void = { _ in }
    /// The text columns hidden (`PrefKey.graphShowMessage`, `graphShowAuthor`, `graphShowDate`); a change applies at
    /// once, without a reload.
    var hiddenColumns: Set<GraphColumn> = []
    /// Esc while the table has the focus; true when it was used (the open search bar closed).
    var onEscape: @MainActor () -> Bool = { false }

    func makeCoordinator() -> GraphTableController { GraphTableController() }

    func makeNSView(context: Context) -> NSScrollView {
        let table = GraphTableView()
        table.style = .plain
        table.backgroundColor = .clear
        table.gridStyleMask = []
        table.intercellSpacing = .zero
        table.usesAutomaticRowHeights = false
        table.allowsMultipleSelection = true
        table.allowsEmptySelection = true
        table.allowsColumnReordering = false
        table.allowsColumnResizing = true
        table.columnAutoresizingStyle = .uniformColumnAutoresizingStyle
        table.focusRingType = .none
        table.headerView = GraphHeaderView(frame: NSRect(x: 0, y: 0, width: 0, height: 26))
        table.cornerView = nil

        let stored = GraphColumn.storedWidths(
            Preferences.defaults.string(forKey: PrefKey.graphColumnWidths.rawValue) ?? "")
        for column in GraphColumn.allCases {
            let tableColumn = NSTableColumn(identifier: column.identifier)
            tableColumn.headerCell = GraphHeaderCell(textCell: column.title)
            tableColumn.minWidth = column.minWidth
            tableColumn.width = stored[column] ?? column.defaultWidth
            #if DEBUG
            // DEBUG `-HistqRefColumnWidth <pt>`: the Branch / Tag column's width at launch (not saved).
            if column == .refs, let width = AppState.launchFlag("-HistqRefColumnWidth").flatMap(Double.init) {
                tableColumn.width = max(column.minWidth, CGFloat(width))
            }
            #endif
            // Only the message column follows the table's width; the others keep theirs.
            tableColumn.resizingMask = column == .message ? [.autoresizingMask, .userResizingMask] : .userResizingMask
            table.addTableColumn(tableColumn)
        }

        let scroll = NSScrollView()
        scroll.documentView = table
        scroll.drawsBackground = false
        scroll.borderType = .noBorder
        scroll.hasVerticalScroller = true
        scroll.hasHorizontalScroller = false
        scroll.autohidesScrollers = true

        context.coordinator.attach(table)
        onTable(table)
        return scroll
    }

    func updateNSView(_ scroll: NSScrollView, context: Context) {
        context.coordinator.update(self)
    }
}

/// The graph's table: the fill column (the message column, or the last visible one when the message is hidden) takes
/// the width the other visible columns leave (at least its minimum), so the columns always fill the card and the last
/// one stays on screen. A right-click asks the controller for the row's
/// (or the badge's) menu; the mouse-down point tells a badge drag from a row drag.
final class GraphTableView: NSTableView {
    /// Where the last mouse down was, in the table: the drag source checks it is on a branch badge.
    private(set) var mouseDownPoint: NSPoint?

    override func mouseDown(with event: NSEvent) {
        let point = convert(event.locationInWindow, from: nil)
        // A pull request chip opens its pull request at once; the row's selection, its detail and a badge drag are
        // left alone (a row select would close the pull request again).
        if event.clickCount == 1, (delegate as? GraphTableController)?.openPullRequest(at: point) == true { return }
        mouseDownPoint = point
        super.mouseDown(with: event)
    }

    override func menu(for event: NSEvent) -> NSMenu? {
        (delegate as? GraphTableController)?.menu(at: convert(event.locationInWindow, from: nil))
    }

    override func keyDown(with event: NSEvent) {
        // Escape: closes the graph search bar when it is open.
        if event.keyCode == 53, event.modifierFlags.isDisjoint(with: [.command, .control, .option, .shift]),
           (delegate as? GraphTableController)?.escape() == true
        {
            return
        }
        super.keyDown(with: event)
    }

    // Edit › Undo / Redo (⌘Z / ⇧⌘Z) reach the table only while it is the first responder.

    @objc func undo(_ sender: Any?) {
        (delegate as? GraphTableController)?.history(redo: false)
    }

    @objc func redo(_ sender: Any?) {
        (delegate as? GraphTableController)?.history(redo: true)
    }

    override func validateUserInterfaceItem(_ item: any NSValidatedUserInterfaceItem) -> Bool {
        switch item.action {
        case #selector(undo(_:)): (delegate as? GraphTableController)?.canHistory(redo: false) ?? false
        case #selector(redo(_:)): (delegate as? GraphTableController)?.canHistory(redo: true) ?? false
        default: super.validateUserInterfaceItem(item)
        }
    }

    /// The width the fill column has as its own when it is not the message column (the last visible one, stretched
    /// to the right edge): restored when it stops filling, and the one saved.
    private(set) var fillOwnWidth: CGFloat?

    /// The column that takes the width the others leave: the message column, else the last visible one.
    var fillColumn: NSTableColumn? {
        let visible = tableColumns.filter { !$0.isHidden }
        return visible.first { $0.identifier == GraphColumn.message.identifier } ?? visible.last
    }

    /// Shows the text columns not in `hidden` and hides the others (Branch / Tag and Graph always show). The columns
    /// keep their own widths: a column that stops filling gets its own width back. True when one changed.
    func setHiddenColumns(_ hidden: Set<GraphColumn>) -> Bool {
        let changes = tableColumns.filter { column in
            guard let id = GraphColumn(rawValue: column.identifier.rawValue), [.message, .author, .date].contains(id)
            else { return false }
            return column.isHidden != hidden.contains(id)
        }
        guard !changes.isEmpty else { return false }
        // The widths before: a width or visibility change may tile at once, stretching the fill column of the moment.
        let oldFill = fillColumn
        let before = tableColumns.map { ($0, $0.width) }
        for column in changes { column.isHidden.toggle() }
        let newFill = fillColumn
        if newFill !== oldFill {
            // The old fill column no longer fills: its own width back. The new one keeps its own width to restore.
            if let oldFill, let own = fillOwnWidth { oldFill.width = max(oldFill.minWidth, own) }
            fillOwnWidth = newFill.flatMap { fill in
                fill.identifier == GraphColumn.message.identifier ? nil : before.first { $0.0 === fill }?.1
            }
        }
        // AppKit's own autoresizing (the table's width changes) goes to the fill column too.
        for column in tableColumns {
            let fills = column === fillColumn
            column.resizingMask = fills ? [.autoresizingMask, .userResizingMask] : .userResizingMask
        }
        return true
    }

    override func tile() {
        super.tile()
        guard let clip = enclosingScrollView?.contentView, let fill = fillColumn else { return }
        let others = tableColumns.reduce(0) { $0 + ($1 === fill || $1.isHidden ? 0 : $1.width) }
        let width = max(fill.minWidth, clip.bounds.width - others)
        // The graph column fills only when every text column is hidden: past its lanes it is empty space.
        if fill.identifier == GraphColumn.graph.identifier, fill.maxWidth < width { fill.maxWidth = width }
        if abs(fill.width - width) > 0.5 { fill.width = width }
    }

    // MARK: Column borders

    /// How far from a border (in points) a mouse down still grabs it.
    private static let borderSlop: CGFloat = 5

    /// Drags the border right of the message column (it resizes the next visible column, author or date, the message
    /// column fills) or right of the author column (author against date, the message column keeps its width), until
    /// the mouse goes up, then saves the widths. Only the borders between visible columns right of a visible message
    /// column: false otherwise, and AppKit resizes the border (the fill column, left or right of it, absorbs it in
    /// `tile`). AppKit cannot resize those two since no column right of them follows the width.
    func trackBorderDrag(_ event: NSEvent, in header: NSTableHeaderView) -> Bool {
        guard let window else { return false }
        let start = header.convert(event.locationInWindow, from: nil)
        let last = tableColumns.last { !$0.isHidden }
        guard let border = [GraphColumn.message, .author].first(where: { column in
            let index = self.column(withIdentifier: column.identifier)
            guard index >= 0, !tableColumns[index].isHidden, tableColumns[index] !== last else { return false }
            return abs(header.headerRect(ofColumn: index).maxX - start.x) <= Self.borderSlop
        }), fillColumn?.identifier == GraphColumn.message.identifier else { return false }
        let widths = columnWidths()
        NSCursor.resizeLeftRight.push()
        defer { NSCursor.pop() }
        while let next = window.nextEvent(matching: [.leftMouseDragged, .leftMouseUp]) {
            applyBorderDrag(border, dx: header.convert(next.locationInWindow, from: nil).x - start.x, from: widths)
            if next.type == .leftMouseUp { break }
        }
        (delegate as? GraphTableController)?.saveColumnWidths()
        return true
    }

    /// The columns' widths now.
    func columnWidths() -> [GraphColumn: CGFloat] {
        var widths: [GraphColumn: CGFloat] = [:]
        for tableColumn in tableColumns {
            if let column = GraphColumn(rawValue: tableColumn.identifier.rawValue) { widths[column] = tableColumn.width }
        }
        return widths
    }

    /// Moves the border right of `border` (message or author) by `dx` from where it was at `start` (the widths at the
    /// mouse down), within the columns' minimum widths: past them the border stops.
    /// Nothing when the border's columns are hidden.
    func applyBorderDrag(_ border: GraphColumn, dx: CGFloat, from start: [GraphColumn: CGFloat]) {
        func visible(_ column: GraphColumn) -> NSTableColumn? {
            tableColumn(withIdentifier: column.identifier).flatMap { $0.isHidden ? nil : $0 }
        }
        guard let message = visible(.message), let messageStart = start[.message] else { return }
        switch border {
        case .message:
            // Left makes the next column (author, or date when the author is hidden) wider; the message column takes
            // the rest (`tile`).
            guard let next = [GraphColumn.author, .date].first(where: { visible($0) != nil }),
                  let right = visible(next), let rightStart = start[next]
            else { return }
            let most = rightStart + messageStart - message.minWidth
            right.width = min(max(rightStart - dx, right.minWidth), most)
        case .author:
            guard let author = visible(.author), let date = visible(.date), let authorStart = start[.author],
                  let dateStart = start[.date]
            else { return }
            let most = authorStart + dateStart - date.minWidth
            let width = min(max(authorStart + dx, author.minWidth), most)
            date.width = dateStart - (width - authorStart)
            author.width = width
        default:
            return
        }
        tile()
        headerView?.needsDisplay = true
    }
}

/// The table's data source and delegate. It keeps the snapshot it shows and compares only generations and counts, so
/// an update costs the same for 50 commits and for 50,000.
@MainActor
final class GraphTableController: NSObject, NSTableViewDataSource, NSTableViewDelegate {
    private weak var table: NSTableView?
    /// The latest view, for its callbacks.
    private var view: GraphView?
    private var log = LogSnapshot()
    private var refs: Refs?
    private var pullRequests: [String: RefBadge.PullRequest] = [:]
    private var remotes: [String] = []
    private var badges: [String: [RefBadge]] = [:]
    private var branchMap = BranchMap()
    /// The faded badge on the selected row (`RefBadge.isGhost`), with the row and commit it was made for.
    private struct Ghost: Equatable {
        let row: Int
        let hash: String
        let badge: RefBadge
    }

    private var ghost: Ghost?
    private var wipDetail: String?
    private var dateFormat: String?
    private let formatter = DateFormatter()
    private var metrics = GraphMetrics(density: "regular")
    /// The most lanes a row of the loaded log draws in (`GraphRow.width`): the graph column is never wider than these
    /// need (`fitGraphColumn`).
    private var logLanes = 0
    /// The graph column's width the user chose (saved, dragged, DEBUG `-HistqGraphWidth`): it shows as far as the log's
    /// lanes allow, so a short first page or a log with fewer lanes never loses it.
    private var wantedGraphWidth: CGFloat?
    /// The lane count and metrics the graph column was last fitted to.
    private var fittedLanes = -1
    private var fittedMetrics: GraphMetrics?
    /// The row density changed in this `update`: the table reloads after the graph column is fitted again.
    private var densityChanged = false
    /// The last selection sent to `onSelect`: a click reports at mouse down (selection change) and again at mouse up
    /// (`action`), only the first goes out.
    private var reported: [GraphItem] = []
    /// While `update` runs: a selection change it causes (a reload, `syncSelection`) is not a user's.
    private var isUpdating = false
    /// The last `GraphView.selection`; a new one is scrolled to once its rows exist.
    private var wanted: [GraphItem] = []
    private var needsScroll = false
    /// The search's dimmed rows, and its last reveal request.
    private var dimming = GraphDimming()
    private var revealToken = 0

    private static let rowViewID = NSUserInterfaceItemIdentifier("graphRow")
    /// The pasteboard type of a dragged branch badge (its `SidebarItem`, as `local:<name>` / `remote:<name>`).
    private static let badgeType = NSPasteboard.PasteboardType("com.math2it.histq.branch-badge")
    /// The badge being dragged.
    private var dragged: RefBadge?

    func attach(_ table: NSTableView) {
        self.table = table
        table.rowHeight = metrics.rowHeight
        table.dataSource = self
        table.delegate = self
        table.target = self
        table.action = #selector(clicked(_:))
        table.doubleAction = #selector(doubleClicked(_:))
        table.registerForDraggedTypes([Self.badgeType])
        table.setDraggingSourceOperationMask(.generic, forLocal: true)
        NotificationCenter.default.addObserver(
            self, selector: #selector(avatarsChanged(_:)), name: AvatarStore.didChange, object: nil)
        #if DEBUG
        if let request = AppState.launchFlag("-HistqColumnDrag") { debugColumnDrag(request) }
        if let request = AppState.launchFlag("-HistqGraphWidth") { debugGraphWidth(request) }
        if let request = AppState.launchFlag("-HistqDensityAfter") { debugDensityAfter(request) }
        #endif
    }

    #if DEBUG
    private static var didGraphWidth = false

    /// DEBUG `-HistqGraphWidth <pt>`: once the table shows rows, asks for that graph column width, as a drag of its
    /// border would, then fits it to the log's lanes (`fitGraphColumn` logs `graph-col …`). Once per launch.
    private func debugGraphWidth(_ request: String) {
        guard !Self.didGraphWidth, let width = Double(request) else { return }
        Self.didGraphWidth = true
        Task { @MainActor [weak self] in
            for _ in 0..<60 {
                try? await Task.sleep(for: .milliseconds(250))
                guard let self, let table = self.table else { return }
                guard table.window != nil, self.rowCount > 0 else { continue }
                try? await Task.sleep(for: .milliseconds(500))
                self.wantedGraphWidth = CGFloat(width)
                self.fittedLanes = -1
                self.fitGraphColumn()
                return
            }
        }
    }

    private static var didDensityAfter = false

    /// DEBUG `-HistqDensityAfter <density>`: about 2 s after the table shows rows, writes `PrefKey.rowDensity` as the
    /// Settings picker does (its `@AppStorage` writes the same defaults), so the graph takes a live density change.
    /// Logs `density <value>`. Once per launch. Launch without `-rowDensity`: the argument domain would win the read.
    private func debugDensityAfter(_ request: String) {
        guard !Self.didDensityAfter else { return }
        Self.didDensityAfter = true
        Task { @MainActor [weak self] in
            for _ in 0..<60 {
                try? await Task.sleep(for: .milliseconds(250))
                guard let self, let table = self.table else { return }
                guard table.window != nil, self.rowCount > 0 else { continue }
                try? await Task.sleep(for: .seconds(2))
                Preferences.defaults.set(request, forKey: PrefKey.rowDensity.rawValue)
                UITiming.probe("density", request)
                try? await Task.sleep(for: .milliseconds(500))
                self.logGraphCells()
                return
            }
        }
    }

    /// Logs `graph-cells column=<w> cells=<w,…>`: the graph column's width and its cells' on screen (they must match).
    private func logGraphCells() {
        guard let table, let column = table.tableColumn(withIdentifier: GraphColumn.graph.identifier) else { return }
        var widths = Set<Int>()
        forEachGraphCell { widths.insert(Int($0.frame.width.rounded())) }
        UITiming.probe("graph-cells", "column=\(Int(column.width.rounded())) cells="
            + widths.sorted().map(String.init).joined(separator: ","))
    }

    private static var didColumnDrag = false

    /// DEBUG `-HistqColumnDrag <column>:<dx>`: once the table shows rows, moves the border right of `<column>`
    /// (message or author) by dx points through `applyBorderDrag`, the drag's own code, and logs the widths before and
    /// after (`columns refs=<w> graph=<w> message=<w> author=<w> date=<w> clip=<w>`). Once per launch.
    private func debugColumnDrag(_ request: String) {
        let parts = request.split(separator: ":")
        guard !Self.didColumnDrag, parts.count == 2, let border = GraphColumn(rawValue: String(parts[0])),
              let dx = Double(parts[1])
        else { return }
        Self.didColumnDrag = true
        Task { @MainActor [weak self] in
            for _ in 0..<60 {
                try? await Task.sleep(for: .milliseconds(250))
                guard let self, let table = self.table as? GraphTableView else { return }
                guard let clip = table.enclosingScrollView?.contentView, clip.bounds.width > 0, table.window != nil,
                      self.rowCount > 0
                else { continue }
                try? await Task.sleep(for: .milliseconds(500))
                Self.logColumns(table)
                table.applyBorderDrag(border, dx: CGFloat(dx), from: table.columnWidths())
                self.saveColumnWidths()
                Self.logColumns(table)
                return
            }
        }
    }

    private static func logColumns(_ table: GraphTableView) {
        let widths = table.columnWidths()
        let columns = GraphColumn.allCases.map { "\($0.rawValue)=\(Int((widths[$0] ?? 0).rounded()))" }
        let clip = table.enclosingScrollView?.contentView.bounds.width ?? 0
        UITiming.probe("columns", columns.joined(separator: " ") + " clip=\(Int(clip.rounded()))")
    }
    #endif

    func update(_ view: GraphView) {
        self.view = view
        isUpdating = true
        updateRows(view)
        if let table = table as? GraphTableView, table.setHiddenColumns(view.hiddenColumns) {
            // The graph column may have stopped filling (or started): it fits its lanes again.
            fittedLanes = -1
            table.headerView?.needsDisplay = true
        }
        fitGraphColumn()
        if densityChanged {
            // Once the column has its new width: every row view and cell the table keeps (on screen, just around it,
            // and reused ones) is made again with the new metrics, row height, highlight and lane folding.
            densityChanged = false
            table?.reloadData()
        }
        if view.dimming.token != dimming.token {
            dimming = view.dimming
            refreshDimming()
        }
        // Before `syncSelection`, whose `scrollRowToVisible` would leave the row at the edge.
        if view.revealToken != revealToken {
            revealToken = view.revealToken
            if let item = view.selection.first, let row = row(of: item) { centerIfHidden(row) }
        }
        syncSelection(view.selection)
        isUpdating = false
        // The map may arrive after the selection (a launch selection, a new log): the selected row follows it here.
        refreshGhost()
    }

    private func updateRows(_ view: GraphView) {
        guard let table else { return }
        var reloadVisible = false

        let newMetrics = GraphMetrics(density: view.rowDensity)
        if newMetrics != metrics {
            metrics = newMetrics
            table.rowHeight = metrics.rowHeight
            // `update` reloads the table once `fitGraphColumn` has fitted the column to the new lane width.
            densityChanged = true
        }
        if view.dateFormat != dateFormat {
            dateFormat = view.dateFormat
            // The user's language without their 24-hour override, which would turn `h:mm a` into `HH:mm`: the
            // preference's format is applied as written.
            formatter.locale = Locale(identifier: Locale.current.identifier)
            formatter.dateFormat = view.dateFormat
            reloadVisible = true
        }
        if view.refs != refs || view.pullRequests != pullRequests || view.remotes != remotes {
            refs = view.refs
            pullRequests = view.pullRequests
            remotes = view.remotes
            badges = view.refs.map { RefBadge.badges(for: $0, pullRequests: pullRequests, remotes: remotes) } ?? [:]
            reloadVisible = true
        }
        if view.branchMap.generation != branchMap.generation { branchMap = view.branchMap }
        let wip = view.status.map(Self.wipDetail)
        if wip != wipDetail {
            wipDetail = wip
            reloadVisible = true
        }

        let old = log
        let new = view.log
        if new.generation != old.generation || new.syntheticRows.count != old.syntheticRows.count
            || new.commits.count < old.commits.count
        {
            // A new load (or a new layout): every row may have changed. A reload of a log already on screen keeps the
            // top visible row where it was (rows above it may have come or gone) and does not scroll to the selection.
            let anchor = old.syntheticRows.count + old.commits.count > 0 ? scrollAnchor(table) : nil
            log = new
            // A load's first pages may need fewer lanes than the whole log: the column keeps the last log's until the
            // load completes, so it does not narrow and widen again on every refresh.
            let lanes = Self.lanes(in: new)
            logLanes = new.isComplete ? lanes : max(lanes, logLanes)
            table.reloadData()
            if let anchor {
                restoreScroll(anchor, in: table)
                needsScroll = false
            }
            return
        }
        log = new
        if new.isComplete, !old.isComplete {
            logLanes = Self.lanes(in: new)
        } else if new.rows.count > old.rows.count {
            logLanes = max(logLanes, Self.lanes(of: new.rows[old.rows.count...]))
        }
        if new.commits.count > old.commits.count {
            // Later pages of the same load: the rows above are unchanged.
            let first = old.syntheticRows.count + old.commits.count
            table.insertRows(at: IndexSet(integersIn: first..<rowCount), withAnimation: [])
        }
        if reloadVisible {
            let visible = table.rows(in: table.visibleRect)
            guard visible.length > 0 else { return }
            table.reloadData(forRowIndexes: IndexSet(integersIn: visible.location..<NSMaxRange(visible)),
                             columnIndexes: IndexSet(integersIn: 0..<table.numberOfColumns))
        }
    }

    private var rowCount: Int { log.syntheticRows.count + log.commits.count }

    /// The most lanes one of `rows` draws in.
    private static func lanes(of rows: ArraySlice<GraphRow>) -> Int {
        rows.reduce(0) { max($0, $1.width) }
    }

    /// The most lanes a row of `log` draws in.
    private static func lanes(in log: LogSnapshot) -> Int {
        max(lanes(of: log.syntheticRows[...]), lanes(of: log.rows[...]))
    }

    // MARK: Graph column width

    /// Fits the graph column to the log's lanes when their count or the row density changed: at least lane 0's node
    /// (`GraphMetrics.minColumnWidth`, every lane folded onto it), at most all of them (`GraphMetrics.width(lanes:)`,
    /// as in GitKraken: only the `trailing` gap right of the last lane), and the wanted width within that. AppKit's
    /// border drag stops at these bounds; the message column fills (`tile`).
    /// The cells on screen take the new lane count. Logs `graph-col max=<w> lanes=<n> visible=<v> width=<w>` (v: the
    /// unpinned lanes, `GraphMetrics.isPinned`).
    private func fitGraphColumn() {
        guard let table, let column = table.tableColumn(withIdentifier: GraphColumn.graph.identifier),
              logLanes != fittedLanes || metrics != fittedMetrics
        else { return }
        let lanesChanged = logLanes != fittedLanes
        fittedLanes = logLanes
        fittedMetrics = metrics
        if wantedGraphWidth == nil { wantedGraphWidth = column.width }
        // Narrow enough for every lane to fold onto lane 0 (`GraphMetrics.drawnX`).
        let minWidth = metrics.minColumnWidth
        // No rows yet (a load in progress): no max, the column keeps its width until the lanes are known.
        let maxWidth = logLanes > 0 ? max(minWidth, metrics.width(lanes: logLanes)) : 10_000
        if lanesChanged { forEachGraphCell { $0.logLanes = self.logLanes; $0.needsDisplay = true } }
        let width = min(max(wantedGraphWidth ?? column.width, minWidth), maxWidth)
        // The width is written while the bounds still hold both the old and the new width, then the bounds are set:
        // a min or max that crosses the current width clamps it without laying the cells out again (no resize
        // notification), and the width write after it is a no-op, so the cells would keep their old width.
        column.minWidth = min(minWidth, column.width, width)
        column.maxWidth = max(maxWidth, column.width, width)
        if abs(column.width - width) > 0.25 { column.width = width }
        column.maxWidth = maxWidth
        column.minWidth = minWidth
        table.tile()
        guard logLanes > 0 else { return }
        let unpinned = (0..<logLanes).filter { !metrics.isPinned(lane: $0, width: column.width) }.count
        UITiming.probe("graph-col", "max=\(Int(maxWidth.rounded())) lanes=\(logLanes) "
            + "visible=\(unpinned) width=\(Int(column.width.rounded()))")
    }

    /// Runs `body` on the graph cells the table has made (on screen and just around it).
    private func forEachGraphCell(_ body: (GraphCellView) -> Void) {
        guard let table else { return }
        let column = table.column(withIdentifier: GraphColumn.graph.identifier)
        guard column >= 0 else { return }
        table.enumerateAvailableRowViews { rowView, _ in
            if let cell = rowView.view(atColumn: column) as? GraphCellView { body(cell) }
        }
    }

    // MARK: Search

    /// Esc in the table: the view's `onEscape` (closes the open search bar). False when it did nothing.
    func escape() -> Bool {
        view?.onEscape() ?? false
    }

    /// Redraws the text cells the table has made whose dimming changed (on screen and just around it).
    private func refreshDimming() {
        guard let table else { return }
        let columns = [GraphColumn.message, .author, .date].map { table.column(withIdentifier: $0.identifier) }
            .filter { $0 >= 0 }
        table.enumerateAvailableRowViews { rowView, row in
            let dimmed = self.dimming.isDimmed(row: row, in: self.log)
            for column in columns {
                guard let cell = rowView.view(atColumn: column) as? GraphTextCellView, cell.isDimmed != dimmed
                else { continue }
                cell.isDimmed = dimmed
                cell.needsDisplay = true
            }
        }
    }

    /// Scrolls `row` to the middle of the rows' area when it is not wholly in it (under the column titles counts as
    /// hidden).
    private func centerIfHidden(_ row: Int) {
        guard let table, let scroll = table.enclosingScrollView, row >= 0, row < table.numberOfRows else { return }
        let clip = scroll.contentView
        let top = clip.contentInsets.top
        let rect = table.rect(ofRow: row)
        let bounds = clip.bounds
        guard rect.minY < bounds.minY + top || rect.maxY > bounds.maxY else { return }
        var origin = bounds.origin
        origin.y = rect.midY - (bounds.height + top) / 2
        clip.scroll(to: clip.constrainBoundsRect(NSRect(origin: origin, size: bounds.size)).origin)
        scroll.reflectScrolledClipView(clip)
    }

    /// The rows on screen before a reload, top first, with their items; `atTop` when the list is scrolled to its top.
    private struct ScrollAnchor {
        let rows: [(row: Int, item: GraphItem)]
        let atTop: Bool
    }

    private func scrollAnchor(_ table: NSTableView) -> ScrollAnchor? {
        let visible = table.rows(in: table.visibleRect)
        guard visible.length > 0 else { return nil }
        let rows = (visible.location..<NSMaxRange(visible)).compactMap { row in item(at: row).map { (row, $0) } }
        // With the header over the rows, the top is at a negative y.
        return ScrollAnchor(rows: rows, atTop: table.visibleRect.minY <= 0.5)
    }

    /// Scrolls by as much as the first anchor row that still exists moved, so it stays at the same place on screen. At
    /// the top the list stays at the top (a new WIP row shows); when every anchor row is gone the offset is kept.
    private func restoreScroll(_ anchor: ScrollAnchor, in table: NSTableView) {
        guard !anchor.atTop, let scroll = table.enclosingScrollView else { return }
        guard let moved = anchor.rows.lazy.compactMap({ old in self.row(of: old.item).map { (old.row, $0) } }).first,
              moved.0 != moved.1
        else { return }
        table.noteNumberOfRowsChanged()
        let clip = scroll.contentView
        var bounds = clip.bounds
        // Every row has the same height.
        bounds.origin.y += CGFloat(moved.1 - moved.0) * (table.rowHeight + table.intercellSpacing.height)
        clip.scroll(to: clip.constrainBoundsRect(bounds).origin)
        scroll.reflectScrolledClipView(clip)
    }

    /// "3 unstaged · 2 staged": the WIP row's counts (untracked and conflicted files count as unstaged).
    private static func wipDetail(_ status: WorkingStatus) -> String {
        WorktreeChanges(status).detail
    }

    // MARK: Rows

    private func item(at row: Int) -> GraphItem? {
        guard row >= 0 else { return nil }
        if row < log.syntheticRows.count {
            let synthetic = log.synthetic[row]
            switch synthetic.kind {
            case .wip: return .wip
            case .stash: return .stash(synthetic.id)
            case .worktreeWIP: return .worktree(synthetic.id)
            }
        }
        let index = row - log.syntheticRows.count
        return index < log.commits.count ? .commit(log.commits[index].hash) : nil
    }

    func numberOfRows(in tableView: NSTableView) -> Int { rowCount }

    func tableView(_ tableView: NSTableView, rowViewForRow row: Int) -> NSTableRowView? {
        let view = tableView.makeView(withIdentifier: Self.rowViewID, owner: nil) as? GraphRowView ?? {
            let view = GraphRowView()
            view.identifier = Self.rowViewID
            return view
        }()
        view.highlightStartX = highlightStartX(forRow: row, in: tableView)
        view.bandInset = metrics.bandInset
        return view
    }

    /// The center of `row`'s node in the table (a row view spans the table's width): the graph column's left edge plus
    /// the node's center, within the graph column.
    private func highlightStartX(forRow row: Int, in table: NSTableView) -> CGFloat {
        let column = table.column(withIdentifier: GraphColumn.graph.identifier)
        guard column >= 0, row >= 0, row < rowCount else { return 0 }
        let rect = table.rect(ofColumn: column)
        let isSynthetic = row < log.syntheticRows.count
        let graphRow = isSynthetic ? log.syntheticRows[row] : log.rows[row - log.syntheticRows.count]
        // From the node's center, as GitKraken: the node hides the highlight's left end (no corner beside it).
        let nodeX = rect.minX + metrics.drawnX(lane: graphRow.lane, width: rect.width)
        return min(max(nodeX, rect.minX), rect.maxX)
    }

    /// Moves the highlight of the rows on screen (a column resize moved the graph column).
    private func refreshHighlights() {
        guard let table else { return }
        table.enumerateAvailableRowViews { rowView, row in
            guard let rowView = rowView as? GraphRowView else { return }
            rowView.highlightStartX = self.highlightStartX(forRow: row, in: table)
            rowView.bandInset = self.metrics.bandInset
        }
    }

    func tableView(_ tableView: NSTableView, viewFor tableColumn: NSTableColumn?, row: Int) -> NSView? {
        guard let tableColumn, let column = GraphColumn(rawValue: tableColumn.identifier.rawValue),
              row >= 0, row < rowCount
        else { return nil }
        let isSynthetic = row < log.syntheticRows.count
        let graphRow = isSynthetic ? log.syntheticRows[row] : log.rows[row - log.syntheticRows.count]
        let commit = isSynthetic ? nil : log.commits[row - log.syntheticRows.count]
        let synthetic = isSynthetic ? log.synthetic[row] : nil

        switch column {
        case .refs:
            let cell = reuse(tableView, column) { RefBadgeCellView() }
            if let worktree = worktree(synthetic) {
                cell.badges = [RefBadge(kind: .worktree, name: worktree.name)]
            } else {
                cell.badges = commit.flatMap { badges[$0.hash] } ?? []
            }
            let ghostBadge = ghost(at: row, commit: commit)
            // After the row's own badges (a detached HEAD, tags): when the column is short, the hint gives way first.
            if let ghostBadge { cell.badges.append(ghostBadge) }
            // Every name in full, also those cut, shown as an icon or behind "+N".
            cell.toolTip = cell.badges.isEmpty ? nil : cell.badges.map(\.name).joined(separator: "\n")
            cell.color = graphRow.color
            cell.metrics = metrics
            cell.needsDisplay = true
            return cell
        case .graph:
            let cell = reuse(tableView, column) { GraphCellView() }
            cell.row = graphRow
            cell.metrics = metrics
            cell.logLanes = logLanes
            cell.avatar = commit.flatMap { $0.isMerge ? nil : avatar(for: $0, in: tableView) }
            // Another worktree's row has its folder's badge: its line runs on to the dashed node here too.
            cell.hasRefs = commit.map { badges[$0.hash] != nil } ?? (worktree(synthetic) != nil)
            cell.hasGhostRef = ghost(at: row, commit: commit) != nil
            if let commit {
                cell.node = commit.isMerge
                    ? .merge : .commit(initials: GraphRowDrawing.initials(of: commit.authorName))
            } else {
                cell.node = synthetic?.kind == .stash ? .stash : .wip
            }
            cell.needsDisplay = true
            return cell
        case .message:
            let cell = reuse(tableView, column) { GraphTextCellView() }
            cell.detail = nil
            cell.isDimmed = dimming.isDimmed(row: row, in: log)
            if let commit {
                cell.text = commit.subject
                cell.tone = .primary
                cell.isItalic = false
            } else if synthetic?.kind == .stash {
                cell.text = stash(synthetic?.id)?.message ?? "Stash"
                cell.tone = .secondary
                cell.isItalic = true
            } else if let worktree = worktree(synthetic) {
                cell.text = "// WIP"
                cell.detail = worktree.changes.map(\.detail).flatMap { $0.isEmpty ? nil : $0 }
                cell.tone = .secondary
                cell.isItalic = true
            } else {
                cell.text = "// WIP"
                cell.detail = wipDetail.flatMap { $0.isEmpty ? nil : $0 }
                cell.tone = .primary
                cell.isItalic = true
            }
            cell.needsDisplay = true
            return cell
        case .author:
            let cell = reuse(tableView, column) { GraphTextCellView() }
            cell.text = commit?.authorName ?? ""
            cell.detail = nil
            cell.isDimmed = dimming.isDimmed(row: row, in: log)
            cell.tone = .secondary
            cell.isItalic = false
            cell.needsDisplay = true
            return cell
        case .date:
            let cell = reuse(tableView, column) { GraphTextCellView() }
            // Formatted only for the rows on screen.
            let date = commit?.authorDate ?? (synthetic?.kind == .stash ? stash(synthetic?.id)?.date : nil)
            cell.text = date.map(formatter.string(from:)) ?? ""
            cell.detail = nil
            cell.isDimmed = dimming.isDimmed(row: row, in: log)
            cell.tone = .secondary
            cell.isItalic = false
            cell.needsDisplay = true
            return cell
        }
    }

    /// The node's avatar, sized for the node at the window's backing scale.
    private func avatar(for commit: Commit, in table: NSTableView) -> NSImage? {
        let scale = table.window?.backingScaleFactor ?? NSScreen.main?.backingScaleFactor ?? 2
        let pixels = Int((metrics.nodeDiameter * scale).rounded(.up))
        return AvatarStore.shared.avatar(email: commit.authorEmail, name: commit.authorName, pixels: pixels)
    }

    /// An avatar arrived (redraw the visible nodes of its author) or the mode changed (redraw every visible node).
    @objc private func avatarsChanged(_ notification: Notification) {
        guard let table else { return }
        let column = table.column(withIdentifier: GraphColumn.graph.identifier)
        let visible = table.rows(in: table.visibleRect)
        guard column >= 0, visible.length > 0 else { return }
        let changed = notification.userInfo?[AvatarStore.emailKey] as? String
        for row in visible.location..<NSMaxRange(visible) {
            let index = row - log.syntheticRows.count
            guard index >= 0, index < log.commits.count,
                  let cell = table.view(atColumn: column, row: row, makeIfNecessary: false) as? GraphCellView
            else { continue }
            let commit = log.commits[index]
            if commit.isMerge { continue }
            if let changed, !AvatarStore.matches(email: commit.authorEmail, name: commit.authorName, changed: changed) {
                continue
            }
            cell.avatar = avatar(for: commit, in: table)
            cell.needsDisplay = true
        }
    }

    private func stash(_ hash: String?) -> Stash? {
        log.stashes.first { $0.hash == hash }
    }

    /// The other worktree of a worktree WIP row.
    private func worktree(_ synthetic: GraphSyntheticRow?) -> WorktreeInfo? {
        guard let synthetic, synthetic.kind == .worktreeWIP else { return nil }
        return log.worktrees.first { $0.path == synthetic.id }
    }

    private func reuse<Cell: NSView>(_ table: NSTableView, _ column: GraphColumn, make: () -> Cell) -> Cell {
        if let cell = table.makeView(withIdentifier: column.identifier, owner: nil) as? Cell { return cell }
        let cell = make()
        cell.identifier = column.identifier
        return cell
    }

    // MARK: Selection

    func tableViewSelectionDidChange(_ notification: Notification) {
        reportSelection()
        // `update` refreshes it once its reload is done.
        if !isUpdating { refreshGhost() }
    }

    // MARK: Ghost badge

    /// `row`'s ghost badge, if it is the one made for this row's commit.
    private func ghost(at row: Int, commit: Commit?) -> RefBadge? {
        guard let ghost, ghost.row == row, ghost.hash == commit?.hash else { return nil }
        return ghost.badge
    }

    /// The ghost the selection calls for: exactly one commit row selected, without a branch badge of its own (a tag or
    /// a detached HEAD may be there), on a branch of the map. Its icon is the branch's kind: the laptop for a local
    /// branch, the cloud for a remote one (named as a remote branch's own badge is).
    private func wantedGhost() -> Ghost? {
        guard let table, table.selectedRowIndexes.count == 1, let row = table.selectedRowIndexes.first else { return nil }
        let index = row - log.syntheticRows.count
        guard index >= 0, index < log.commits.count else { return nil }
        let hash = log.commits[index].hash
        let hasBranch = badges[hash]?.contains { if case .branch = $0.kind { true } else { false } } ?? false
        guard !hasBranch, let name = branchMap.branch(at: index, in: log) else { return nil }
        let isLocal = refs?.localBranches.contains { $0.name == name } ?? false
        var label: String?
        if !isLocal, let refs, let remote = refs.remoteBranches.first(where: { $0.name == name }) {
            label = RefBadge.remoteLabel(of: remote, singleRemote: RefBadge.singleRemote(refs, remotes: remotes))
        }
        return Ghost(row: row, hash: hash, badge: RefBadge(
            kind: .branch(isLocal: isLocal, isRemote: !isLocal, isHead: false), name: name, label: label,
            isGhost: true))
    }

    /// Moves the ghost to the selection's: reloads only the refs and graph cells of the row it leaves and the row it
    /// goes to.
    private func refreshGhost() {
        guard let table else { return }
        let new = wantedGhost()
        guard new != ghost else { return }
        let rows = IndexSet([ghost?.row, new?.row].compactMap { $0 }.filter { $0 < table.numberOfRows })
        ghost = new
        let columns = IndexSet([GraphColumn.refs, .graph].map { table.column(withIdentifier: $0.identifier) }
            .filter { $0 >= 0 })
        guard !rows.isEmpty, !columns.isEmpty else { return }
        table.reloadData(forRowIndexes: rows, columnIndexes: columns)
    }

    /// A click: the selection already changed at mouse down; a click that did not change it reports nothing new. A
    /// click on another worktree's WIP row opens that worktree (only a click: arrows never open tabs).
    @objc func clicked(_ sender: Any?) {
        reportSelection()
        guard let table, case .worktree(let path)? = item(at: table.clickedRow),
              table.selectedRowIndexes == IndexSet(integer: table.clickedRow)
        else { return }
        view?.onOpenWorktree(path)
    }

    /// Checks out the double-clicked row (the hook); the first click of the pair has already selected it.
    @objc func doubleClicked(_ sender: Any?) {
        guard let table, let item = item(at: table.clickedRow) else { return }
        view?.onActivate(item)
    }

    /// Selects the rows of `selection` when the table shows another selection (a parent jump, the default selection,
    /// rows moved by a reload), and scrolls to a new one. `reported` takes it first, so it is not sent back.
    private func syncSelection(_ selection: [GraphItem]) {
        guard let table else { return }
        if selection != wanted {
            wanted = selection
            needsScroll = true
        }
        let current = table.selectedRowIndexes.compactMap(item(at:))
        reported = selection
        guard current != selection else {
            needsScroll = false
            return
        }
        let rows = IndexSet(selection.compactMap(row(of:)))
        table.selectRowIndexes(rows, byExtendingSelection: false)
        if needsScroll, let first = rows.first {
            table.scrollRowToVisible(first)
            needsScroll = false
        }
    }

    private func row(of item: GraphItem) -> Int? {
        switch item {
        case .wip:
            return log.synthetic.firstIndex { $0.kind == .wip }
        case .stash(let hash):
            return log.synthetic.firstIndex { $0.kind == .stash && $0.id == hash }
        case .commit(let hash):
            // The log's index first: a search move to a commit far down a 50,000-commit log stays instant.
            let index = log.commitIndex[hash].flatMap {
                log.commits.indices.contains($0) && log.commits[$0].hash == hash ? $0 : nil
            }
                ?? log.commits.firstIndex { $0.hash == hash }
            return index.map { $0 + log.syntheticRows.count }
        case .worktree(let path):
            return log.synthetic.firstIndex { $0.kind == .worktreeWIP && $0.id == path }
        }
    }

    /// Worktree rows are left out: a selection of only those (a click on one, an arrow onto one) reports nothing and
    /// the detail stays.
    private func reportSelection() {
        guard let table, !isUpdating else { return }
        let items = table.selectedRowIndexes.compactMap(item(at:)).filter {
            if case .worktree = $0 { false } else { true }
        }
        guard items != reported, !items.isEmpty || table.selectedRowIndexes.isEmpty else { return }
        reported = items
        view?.onSelect(items)
    }

    // MARK: Undo

    func canHistory(redo: Bool) -> Bool { view?.canUndo(redo) ?? false }

    func history(redo: Bool) {
        guard canHistory(redo: redo) else { return }
        view?.onUndo(redo)
    }

    // MARK: Menus

    /// The menu of the row at `point` (in the table), with the badge under it; nil outside the rows.
    func menu(at point: NSPoint) -> NSMenu? {
        guard let table, let view else { return nil }
        let row = table.row(at: point)
        guard let item = item(at: row) else { return nil }
        let entries = view.menuEntries(item, badge(at: point))
        return entries.isEmpty ? nil : MenuBuilder.menu(entries)
    }

    /// Opens the pull request whose chip is at `point` (in the table); false when there is none.
    func openPullRequest(at point: NSPoint) -> Bool {
        guard let table, let view, let cell = cell(at: point),
              let pull = cell.pullRequest(at: cell.convert(point, from: table))
        else { return false }
        view.onOpenPullRequest(pull.number)
        return true
    }

    /// The badge drawn at `point` (in the table).
    private func badge(at point: NSPoint) -> RefBadge? {
        guard let table, let cell = cell(at: point) else { return nil }
        return cell.badge(at: cell.convert(point, from: table))
    }

    // MARK: Drag and drop

    /// Only a branch badge drags (its row would otherwise start a row drag, which the graph does not have): a drag
    /// anywhere else keeps the table's own drag-to-select.
    func tableView(_ tableView: NSTableView, pasteboardWriterForRow row: Int) -> (any NSPasteboardWriting)? {
        guard let point = (tableView as? GraphTableView)?.mouseDownPoint, tableView.row(at: point) == row,
              let badge = badge(at: point), let item = badge.sidebarItem, item.branchName != nil
        else { return nil }
        dragged = badge
        let pasteboardItem = NSPasteboardItem()
        pasteboardItem.setString(badge.name, forType: Self.badgeType)
        return pasteboardItem
    }

    /// The drag image is the badge alone, under the pointer.
    func tableView(_ tableView: NSTableView, draggingSession session: NSDraggingSession, willBeginAt screenPoint: NSPoint,
                   forRowIndexes rowIndexes: IndexSet)
    {
        guard let badge = dragged, let point = (tableView as? GraphTableView)?.mouseDownPoint,
              let cell = cell(at: point)
        else { return }
        let image = cell.dragImage(of: badge, scale: tableView.window?.backingScaleFactor ?? 2)
        session.draggingFormation = .none
        session.enumerateDraggingItems(
            options: [], for: tableView, classes: [NSPasteboardItem.self], searchOptions: [:]
        ) { item, _, _ in
            let origin = NSPoint(x: point.x - image.size.width / 2, y: point.y - image.size.height / 2)
            item.setDraggingFrame(NSRect(origin: origin, size: image.size), contents: image)
        }
    }

    func tableView(_ tableView: NSTableView, draggingSession session: NSDraggingSession, endedAt screenPoint: NSPoint,
                   operation: NSDragOperation)
    {
        dragged = nil
    }

    /// A drop is only on another branch badge.
    func tableView(_ tableView: NSTableView, validateDrop info: any NSDraggingInfo, proposedRow row: Int,
                   proposedDropOperation dropOperation: NSTableView.DropOperation) -> NSDragOperation
    {
        let point = tableView.convert(info.draggingLocation, from: nil)
        guard dropTarget(at: point) != nil else { return [] }
        tableView.setDropRow(tableView.row(at: point), dropOperation: .on)
        return .generic
    }

    /// Opens the Merge / Rebase / Fast-forward menu where the badge was dropped, after the drag has ended.
    func tableView(_ tableView: NSTableView, acceptDrop info: any NSDraggingInfo, row: Int,
                   dropOperation: NSTableView.DropOperation) -> Bool
    {
        let point = tableView.convert(info.draggingLocation, from: nil)
        guard let source = dragged, let target = dropTarget(at: point), let view else { return false }
        let entries = view.dropEntries(source, target)
        guard !entries.isEmpty else { return false }
        let menu = MenuBuilder.menu(entries)
        DispatchQueue.main.async { [weak tableView] in
            guard let tableView else { return }
            menu.popUp(positioning: nil, at: point, in: tableView)
        }
        return true
    }

    /// The branch badge under `point` that the dragged badge can be dropped on.
    private func dropTarget(at point: NSPoint) -> RefBadge? {
        guard let source = dragged, let target = badge(at: point), target != source,
              target.sidebarItem?.branchName != nil
        else { return nil }
        return target
    }

    private func cell(at point: NSPoint) -> RefBadgeCellView? {
        guard let table else { return nil }
        let column = table.column(withIdentifier: GraphColumn.refs.identifier)
        let row = table.row(at: point)
        guard row >= 0, column >= 0, table.column(at: point) == column else { return nil }
        return table.view(atColumn: column, row: row, makeIfNecessary: false) as? RefBadgeCellView
    }

    // MARK: Columns

    /// Saves the widths after the user drags a column edge (not when the table's own width changes).
    /// Any width change (AppKit's resize, the border drags, `tile`) also moves the selected rows' highlight.
    /// A graph column resize also redraws its cells on screen: its nodes fold (`GraphMetrics.drawnX`)
    /// point by point with its width.
    func tableViewColumnDidResize(_ notification: Notification) {
        refreshHighlights()
        let resized = notification.userInfo?["NSTableColumn"] as? NSTableColumn
        if resized?.identifier == GraphColumn.graph.identifier { forEachGraphCell { $0.needsDisplay = true } }
        guard let table, let header = table.headerView, header.resizedColumn >= 0 else { return }
        // The user dragged the graph column's border: that is the width they want (within the lanes' bounds). Not
        // while it fills (every text column hidden): `tile` sets that width.
        if table.tableColumns[header.resizedColumn].identifier == GraphColumn.graph.identifier,
           (table as? GraphTableView)?.fillColumn !== table.tableColumns[header.resizedColumn]
        {
            wantedGraphWidth = table.tableColumns[header.resizedColumn].width
        }
        saveColumnWidths()
    }

    /// Saves the widths in `PrefKey.graphColumnWidths` (the message column's is ignored on restore: it fills). The
    /// graph column saves its wanted width, not the one a repo with few lanes fits it to; another column that fills
    /// (the message column hidden) its own width, not the stretched one. Hidden columns keep theirs.
    func saveColumnWidths() {
        guard let table else { return }
        let graphTable = table as? GraphTableView
        let encoded = table.tableColumns
            .map { column in
                let width = column.identifier == GraphColumn.graph.identifier
                    ? wantedGraphWidth ?? column.width
                    : column === graphTable?.fillColumn ? graphTable?.fillOwnWidth ?? column.width : column.width
                return "\(column.identifier.rawValue):\(Int(width.rounded()))"
            }
            .joined(separator: ",")
        Preferences.defaults.set(encoded, forKey: PrefKey.graphColumnWidths.rawValue)
    }
}
