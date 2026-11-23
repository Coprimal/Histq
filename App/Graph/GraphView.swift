// The commit graph: an NSTableView with its columns (BRANCH / TAG, GRAPH, COMMIT MESSAGE, AUTHOR, TIME).
// Rows: the WIP row (when the working tree has changes), a WIP row per other worktree with changes (labeled with its
// folder's name, grey and faded; a click shows its changes, a double-click opens its tab), the stash rows, then the
// commits, laid out by `GraphLayout`.
// The table only asks for the rows on screen, so its cost does not grow with the log: a later page of the same load is
// inserted as rows, a new load reloads. A click selects at once (`action`); a double-click calls the checkout hook
// (`doubleAction`) without delaying the single click. A click on a branch badge's pull request chip opens that pull
// request at mouse down instead of selecting the row. `GraphVisibilityChip` floats over its header while branches are
// hidden or soloed.
import AppKit
import HistqCore
import SwiftUI

/// What a graph row stands for: what the selection callback and the double-click hook get.
enum GraphItem: Hashable, Sendable {
    case wip
    /// A stash, by its commit hash.
    case stash(String)
    case commit(String)
    /// Another worktree's WIP row, by the worktree's path: a click shows its changes (read-only).
    case worktree(String)
}

/// Where a tab's graph was scrolled when its view went away (a switch to another tab), kept by its session: the tab's
/// graph shows the same rows when it comes back. `anchor` is the first row wholly below the column titles and `offset`
/// how far below them it was; `atTop` when the list was at its top (a new WIP row then shows). `selection` is the
/// selection it was saved with: another selection meanwhile is revealed instead.
struct GraphScrollPosition: Equatable {
    var anchor: GraphItem?
    var offset: CGFloat
    var atTop: Bool
    var selection: [GraphItem]
}

/// The graph's columns, left to right. Widths are resizable and saved in `PrefKey.graphColumnWidths`; the message
/// column takes what the others leave. Settings › Appearance can hide the message, author and date columns.
enum GraphColumn: String, CaseIterable {
    case refs, graph, message, author, date

    var title: String {
        switch self {
        case .refs: "Branch / Tag"
        case .graph: "Graph"
        case .message: "Commit message"
        case .author: "Author"
        case .date: "Time"
        }
    }

    /// The header's icon when the column is too narrow for its title.
    var compactSymbol: String? {
        switch self {
        case .author: "person"
        default: nil
        }
    }

    var defaultWidth: CGFloat {
        switch self {
        // Fits a 20-character branch name with its icon whole (user, 2026-11-19: 116 cut most names).
        case .refs: 150
        // Four lanes at the regular row density.
        case .graph: GraphMetrics(density: "regular").width(lanes: 4)
        case .message: 240
        case .author: 76
        // Fits "12/31/25 @ 23:00", the default format since 7.5.
        case .date: 120
        }
    }

    /// `defaultWidth` at `textSize`, for a column without a stored width: Branch / Tag and Author grow with a larger
    /// text (never narrower than at Regular, so Small cuts no badge), and Time fits a date in `dateFormat` whole. The
    /// same as `defaultWidth` at Regular with the default format.
    @MainActor func defaultWidth(textSize: TextSize, dateFormat: String) -> CGFloat {
        switch self {
        case .refs, .author: max(defaultWidth, textSize.scaled(defaultWidth))
        case .date: max(defaultWidth, textSize.scaled(defaultWidth),
                        GraphTextCellView.fittingWidth(Self.sampleDate(dateFormat), textSize: textSize))
        case .graph, .message: defaultWidth
        }
    }

    /// A wide date in `dateFormat` (Wednesday, December 31 at 23:58), formatted as the date cells are.
    private static func sampleDate(_ dateFormat: String) -> String {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: Locale.current.identifier)
        formatter.dateFormat = dateFormat
        let date = Calendar.current.date(from: DateComponents(year: 2025, month: 12, day: 31, hour: 23, minute: 58))
        return date.map(formatter.string(from:)) ?? ""
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

/// The graph table. `log` gives the rows; `refs` the badges; `status` the WIP row's counts. `dateFormat`,
/// `rowDensity` and `textSize` are `PrefKey.dateFormat`, `PrefKey.rowDensity` and `PrefKey.textSize`. `onSelect` gets
/// the selected rows (in row order) as soon as the selection changes (a click, ⌘/⇧-click, the arrow keys);
/// `onActivate` gets a double-clicked row.
/// `selection` is the selection the table follows: a new one (a parent jump) is selected and centred when off screen, without an
/// `onSelect` echo. ⌘Z / ⇧⌘Z while the table has the focus ask `canUndo` and run `onUndo` (`redo` true for Redo);
/// a text field keeps its own undo, since its field editor answers first.
struct GraphView: NSViewRepresentable {
    let log: LogSnapshot
    let refs: Refs?
    let status: WorkingStatus?
    let dateFormat: String
    let rowDensity: String
    var textSize = TextSize.regular
    /// `PrefKey.laneColors`: the lanes' palette and line width (the rows carry its palette indices).
    var laneColors = LaneColors.vivid
    var selection: [GraphItem] = []
    var onSelect: @MainActor ([GraphItem]) -> Void = { _ in }
    /// A double-clicked row; `badge` is the ref badge under the pointer, if any.
    var onActivate: @MainActor (GraphItem, RefBadge?) -> Void = { _, _ in }
    /// The context menu of a row; `badge` is the ref badge under the pointer, if any.
    var menuEntries: @MainActor (GraphItem, RefBadge?) -> [MenuEntry] = { _, _ in [] }
    /// The menu of a branch badge dropped on another (source, target).
    var dropEntries: @MainActor (RefBadge, RefBadge) -> [MenuEntry] = { _, _ in [] }
    var canUndo: @MainActor (_ redo: Bool) -> Bool = { _ in false }
    var onUndo: @MainActor (_ redo: Bool) -> Void = { _ in }
    /// The open pull requests by remote branch (`GitHubStore.branchPullRequests`): their chips on the branch badges.
    var pullRequests: [String: RefBadge.PullRequest] = [:]
    /// The repo's remote names (`RepoSession.remotes`): with one remote, a remote branch's badge drops the remote
    /// from its name (`RefBadge.remoteLabel`).
    var remotes: [String] = []
    /// The branches checked out in the other worktrees, as full refs (`refs/heads/wt`): their badges show the worktree
    /// icon.
    var otherWorktreeBranches: Set<String> = []
    /// The repo's remotes' URLs by name (`RepoSession.remotes`): the cloud on a remote's badges gives way to its
    /// owner's logo (`AvatarStore.ownerAvatar`).
    var remoteURLs: [String: String] = [:]
    /// A click on a pull request chip, with its number.
    var onOpenPullRequest: @MainActor (Int) -> Void = { _ in }
    /// The branch each commit is on (`RepoSession.branchMap`): a lone selected commit without a branch badge of its own
    /// shows its branch's badge faded.
    var branchMap = BranchMap()
    /// The worktrees reaching each commit (`RepoSession.worktreeMap`): one worktree is lit at a time (this one, or the
    /// one of the selected rows), every other worktree's commits fade with their lines and WIP rows.
    var worktreeMap = WorktreeMap()
    /// The rows the graph search dims (`GraphSearch.dimming`).
    var dimming = GraphDimming()
    /// New with each move to a search match: the selected row is centred when it is off screen.
    var revealToken = 0
    /// The height of what floats over the bottom of the rows (the open search bar): the rows scroll clear of it, and a
    /// row under it counts as hidden.
    var bottomInset: CGFloat = 0
    /// The table, once made (the search gives it the focus back when it closes).
    var onTable: @MainActor (NSTableView) -> Void = { _ in }
    /// The text columns hidden (`PrefKey.graphShowMessage`, `graphShowAuthor`, `graphShowDate`); a change applies at
    /// once, without a reload.
    var hiddenColumns: Set<GraphColumn> = []
    /// Esc while the table has the focus; true when it was used (the open search bar closed).
    var onEscape: @MainActor () -> Bool = { false }
    /// Where the tab's graph was when its last view went away (`GraphScrollPosition`): a new view starts there, else on
    /// the top with the selection revealed. `onScroll` gets the position when the view goes away.
    var scrollPosition: GraphScrollPosition?
    var onScroll: @MainActor (GraphScrollPosition) -> Void = { _ in }
    @Environment(\.tabIsShown) private var tabIsShown
    /// The window's model, for its spotlight registry (a constant: reading it observes nothing).
    @Environment(WindowModel.self) private var windowModel: WindowModel?

    func makeCoordinator() -> GraphTableController { GraphTableController() }

    static func dismantleNSView(_ scroll: NSScrollView, coordinator: GraphTableController) {
        coordinator.saveScroll()
        coordinator.detachSpotlight()
    }

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
            let header = GraphHeaderCell(textCell: column.title)
            header.symbolName = column.compactSymbol
            tableColumn.headerCell = header
            if header.symbolName != nil { tableColumn.headerToolTip = column.title }
            tableColumn.minWidth = column.minWidth
            tableColumn.width = stored[column] ?? column.defaultWidth(textSize: textSize, dateFormat: dateFormat)
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
        // `bottomInset` sets the insets; the graph card sits below the title bar, so there is nothing to adjust for.
        scroll.automaticallyAdjustsContentInsets = false
        scroll.isHidden = !tabIsShown

        context.coordinator.attach(table)
        onTable(table)
        return scroll
    }

    func updateNSView(_ scroll: NSScrollView, context: Context) {
        if scroll.isHidden == tabIsShown { scroll.isHidden = !tabIsShown }
        if scroll.contentInsets.bottom != bottomInset { scroll.contentInsets.bottom = bottomInset }
        context.coordinator.update(self)
        // Only the shown tab's WIP row can be framed.
        context.coordinator.syncSpotlight(tabIsShown ? windowModel?.spotlight : nil)
    }
}

/// The graph's table: the fill column (the message column, or the last visible one when the message is hidden) takes
/// the width the other visible columns leave (at least its minimum), so the columns always fill the card and the last
/// one stays on screen. A right-click asks the controller for the row's
/// (or the badge's) menu; the mouse-down point tells a badge drag from a row drag. A branch badge shows a hand cursor.
final class GraphTableView: NSTableView {
    /// Where the last mouse down was, in the table: the drag source checks it is on a branch badge.
    private(set) var mouseDownPoint: NSPoint?

    override func mouseDown(with event: NSEvent) {
        let point = convert(event.locationInWindow, from: nil)
        controller?.beginPress(at: point, modifiers: event.modifierFlags)
        defer { controller?.endPress() }
        // A pull request chip opens its pull request at once; the row's selection, its detail and a badge drag are
        // left alone (a row select would close the pull request again).
        if event.clickCount == 1, controller?.openPullRequest(at: point) == true { return }
        // The Open Worktree pill of a selected worktree row opens its tab.
        if controller?.openWorktree(at: point) == true { return }
        mouseDownPoint = point
        if showsOpenHand { NSCursor.closedHand.set() }
        super.mouseDown(with: event)
        updateCursor(at: convert(window?.mouseLocationOutsideOfEventStream ?? event.locationInWindow, from: nil))
    }

    // A branch badge shows the open hand under the pointer (it drags), the closed hand while held.

    /// The hand is the cursor this table set (the arrow is set back only then).
    private var showsOpenHand = false
    private var cursorArea: NSTrackingArea?

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        if let cursorArea { removeTrackingArea(cursorArea) }
        let area = NSTrackingArea(rect: bounds,
                                  options: [.mouseMoved, .mouseEnteredAndExited, .activeInActiveApp, .inVisibleRect],
                                  owner: self)
        addTrackingArea(area)
        cursorArea = area
    }

    override func mouseMoved(with event: NSEvent) {
        super.mouseMoved(with: event)
        let point = convert(event.locationInWindow, from: nil)
        updateCursor(at: point)
        controller?.hoverRefs(at: point)
        controller?.hoverOpenButton(at: point)
    }

    override func mouseExited(with event: NSEvent) {
        super.mouseExited(with: event)
        updateCursor(at: nil)
        controller?.hoverRefs(at: nil)
        controller?.hoverOpenButton(at: nil)
    }

    private var controller: GraphTableController? { delegate as? GraphTableController }

    private func updateCursor(at point: NSPoint?) {
        let hand = point.map { (delegate as? GraphTableController)?.canDragBadge(at: $0) == true } ?? false
        if hand {
            NSCursor.openHand.set()
        } else if showsOpenHand {
            NSCursor.arrow.set()
        }
        showsOpenHand = hand
    }

    // No mouse moves during a drag: the row under it shows its badge stack here (on every move: the table validates a
    // drop only when its proposed row changes), so a badge hidden behind "+N" is a drop target too.
    override func draggingUpdated(_ sender: any NSDraggingInfo) -> NSDragOperation {
        controller?.hoverRefs(at: convert(sender.draggingLocation, from: nil))
        return super.draggingUpdated(sender)
    }

    override func draggingExited(_ sender: (any NSDraggingInfo)?) {
        super.draggingExited(sender)
        controller?.hoverRefs(at: nil)
    }

    override func menu(for event: NSEvent) -> NSMenu? {
        let point = convert(event.locationInWindow, from: nil)
        controller?.beginPress(at: point, modifiers: event.modifierFlags)
        defer { controller?.endPress() }
        return controller?.menu(at: point)
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

    // Edit › Undo / Redo (⌘Z / ⇧⌘Z) reach the table only while it is the first responder. Refused while the
    // onboarding runs over the window: nil-targeted, so the app delegate's menu gate never sees them; the table asks it
    // through `NSApp.delegate` (`AppDelegate.isOnboarding(in:)`, its window's entry), as the tab strip asks for moves.

    @objc func undo(_ sender: Any?) {
        guard !isOnboarding else { return }
        (delegate as? GraphTableController)?.history(redo: false)
    }

    @objc func redo(_ sender: Any?) {
        guard !isOnboarding else { return }
        (delegate as? GraphTableController)?.history(redo: true)
    }

    /// The onboarding runs over this table's window.
    private var isOnboarding: Bool {
        (NSApp.delegate as? AppDelegate)?.isOnboarding(in: window) == true
    }

    override func validateUserInterfaceItem(_ item: any NSValidatedUserInterfaceItem) -> Bool {
        switch item.action {
        case #selector(undo(_:)):
            !isOnboarding && (delegate as? GraphTableController)?.canHistory(redo: false) ?? false
        case #selector(redo(_:)):
            !isOnboarding && (delegate as? GraphTableController)?.canHistory(redo: true) ?? false
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
        // AppKit tiles on every step of a live column drag, but tells `tableViewColumnDidResize` only when it ends:
        // the selected rows' highlight follows the graph column here, while the mouse is still down.
        defer { (delegate as? GraphTableController)?.refreshHighlights() }
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
    private var otherWorktreeBranches: Set<String> = []
    private var remoteURLs: [String: String] = [:]
    /// The logos of the remotes' owners loaded so far, by remote name (`RefBadgeCellView.remoteAvatars`).
    private var remoteAvatars: [String: NSImage] = [:]
    private var badges: [String: [RefBadge]] = [:]
    private var branchMap = BranchMap()
    private var worktreeMap = WorktreeMap()
    /// The other worktree whose rows show unfaded (one `WorktreeMap` bit): the selected rows'; 0 for this one's.
    private var litWorktree: UInt64 = 0
    /// The lit worktree's `WorktreeMap` bit.
    private var litBit: UInt64 { litWorktree == 0 ? worktreeMap.head : litWorktree }
    /// The faded badge on the selected row (`RefBadge.isGhost`), with the row and commit it was made for.
    private struct Ghost: Equatable {
        let row: Int
        let hash: String
        let badge: RefBadge
    }

    private var ghost: Ghost?
    private var wipChanges: WorktreeChanges?
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
    /// The row density or the text size changed in this `update`: the table reloads after the graph column is fitted
    /// again.
    private var densityChanged = false
    /// The last selection sent to `onSelect`: a click reports at mouse down (selection change) and again at mouse up
    /// (`action`), only the first goes out.
    private var reported: [GraphItem] = []
    /// While `update` runs: a selection change it causes (a reload, `syncSelection`) is not a user's.
    private var isUpdating = false
    /// The last `GraphView.selection`; a new one is scrolled to once its rows exist.
    private var wanted: [GraphItem] = []
    private var needsScroll = false
    /// The view's first scroll position is set (`placeInitially`): only once it has rows and its clip has its size.
    private var isPlaced = false
    /// The search's dimmed rows, and its last reveal request.
    private var dimming = GraphDimming()
    private var revealToken = 0

    private static let rowViewID = NSUserInterfaceItemIdentifier("graphRow")
    /// The pasteboard type of a dragged branch badge (its `SidebarItem`, as `local:<name>` / `remote:<name>`).
    private static let badgeType = NSPasteboard.PasteboardType("com.math2it.histq.branch-badge")
    /// The badge being dragged.
    private var dragged: RefBadge?
    /// The hover stack of a row's badges (`hoverRefs`), the row and the cell it covers.
    private var stackOverlay: RefBadgeCellView?
    private var stackRow = -1
    private weak var coveredCell: RefBadgeCellView?
    /// The message cell whose Open Worktree pill is under the pointer (lit).
    private weak var litOpenButton: GraphTextCellView?
    /// While a press on a stacked badge is tracked: the row under it, the stack's row, which it is for, and the
    /// table's selection and the event's modifier keys when it began.
    private var pressRow: (row: Int, stack: Int, selection: IndexSet, modifiers: NSEvent.ModifierFlags)?

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
        // A scroll moves the rows under a still pointer: the hover stack would stay on the wrong row.
        if let clip = table.enclosingScrollView?.contentView {
            clip.postsBoundsChangedNotifications = true
            NotificationCenter.default.addObserver(
                self, selector: #selector(scrolled(_:)), name: NSView.boundsDidChangeNotification, object: clip)
            // The clip has no size at the first `update`: the first position waits for it.
            clip.postsFrameChangedNotifications = true
            NotificationCenter.default.addObserver(
                self, selector: #selector(clipResized(_:)), name: NSView.frameDidChangeNotification, object: clip)
        }
        #if DEBUG
        if let request = AppState.launchFlag("-HistqColumnDrag") { debugColumnDrag(request) }
        if let request = AppState.launchFlag("-HistqGraphWidth") { debugGraphWidth(request) }
        if let request = AppState.launchFlag("-HistqDensityAfter") { debugDensityAfter(request) }
        if let request = AppState.launchFlag("-HistqHoverRefs") { debugHoverRefs(request) }
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

    private static var didHoverRefs = false

    /// DEBUG `-HistqHoverRefs <ref>`: once the table shows rows, hovers the refs cell of the row with that ref as the
    /// pointer would (`hoverRefs`), so a background shot shows its badge stack. Logs `hover-refs row=<n> stack=<0|1>`.
    /// Once per launch.
    private func debugHoverRefs(_ name: String) {
        guard !Self.didHoverRefs else { return }
        Self.didHoverRefs = true
        Task { @MainActor [weak self] in
            for _ in 0..<60 {
                try? await Task.sleep(for: .milliseconds(250))
                guard let self, let table = self.table else { return }
                guard table.window != nil, self.rowCount > 0 else { continue }
                try? await Task.sleep(for: .milliseconds(500))
                let column = table.column(withIdentifier: GraphColumn.refs.identifier)
                guard let row = (0..<self.rowCount).first(where: { row in
                    guard case .commit(let index) = self.log.entry(at: row) else { return false }
                    return self.badges[self.log.commits[index].hash]?.contains { $0.name == name } == true
                }), column >= 0 else { return }
                table.scrollRowToVisible(row)
                let rect = table.frameOfCell(atColumn: column, row: row)
                self.hoverRefs(at: NSPoint(x: rect.midX, y: rect.midY))
                UITiming.probe("hover-refs", "row=\(row) stack=\(self.stackOverlay?.superview != nil ? 1 : 0)")
                return
            }
        }
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
            hideStack()
            table?.reloadData()
        }
        if view.dimming.token != dimming.token {
            dimming = view.dimming
            refreshDimming()
        }
        // Before `syncSelection`, which then finds the row on screen.
        if view.revealToken != revealToken {
            revealToken = view.revealToken
            if let item = view.selection.first, let row = row(of: item) { centerIfHidden(row) }
        }
        syncSelection(view.selection)
        refreshWorktreeFade()
        placeInitially()
        isUpdating = false
        // The map may arrive after the selection (a launch selection, a new log): the selected row follows it here.
        refreshGhost()
    }

    /// The text columns without a stored width take their default for the view's text size and date format
    /// (`GraphColumn.defaultWidth(textSize:dateFormat:)`); a stored width, and the column that fills, keep theirs. Not
    /// saved: only a drag saves the widths.
    private func fitDefaultWidths(_ view: GraphView) {
        guard let table = table as? GraphTableView else { return }
        let stored = GraphColumn.storedWidths(
            Preferences.defaults.string(forKey: PrefKey.graphColumnWidths.rawValue) ?? "")
        for column in [GraphColumn.refs, .author, .date] where stored[column] == nil {
            guard let tableColumn = table.tableColumn(withIdentifier: column.identifier),
                  tableColumn !== table.fillColumn
            else { continue }
            let width = column.defaultWidth(textSize: view.textSize, dateFormat: view.dateFormat)
            if abs(tableColumn.width - width) > 0.5 { tableColumn.width = width }
        }
    }

    private func updateRows(_ view: GraphView) {
        guard let table else { return }
        var reloadVisible = false

        let newMetrics = GraphMetrics(density: view.rowDensity, textSize: view.textSize, laneColors: view.laneColors)
        // Not on the first update (`dateFormat` still nil): `makeNSView` has set the widths for this view already, and
        // a refit would drop the DEBUG `-HistqRefColumnWidth`.
        if dateFormat != nil, newMetrics.textSize != metrics.textSize || view.dateFormat != dateFormat {
            fitDefaultWidths(view)
        }
        if newMetrics != metrics {
            metrics = newMetrics
            table.rowHeight = metrics.rowHeight
            // The column titles take the text size too; the reload does not redraw the header.
            for column in table.tableColumns { (column.headerCell as? GraphHeaderCell)?.textSize = metrics.textSize }
            table.headerView?.needsDisplay = true
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
        if view.refs != refs || view.pullRequests != pullRequests || view.remotes != remotes
            || view.otherWorktreeBranches != otherWorktreeBranches
        {
            refs = view.refs
            pullRequests = view.pullRequests
            remotes = view.remotes
            otherWorktreeBranches = view.otherWorktreeBranches
            badges = view.refs.map {
                RefBadge.badges(for: $0, pullRequests: pullRequests, remotes: remotes,
                                otherWorktreeBranches: otherWorktreeBranches)
            } ?? [:]
            reloadVisible = true
        }
        if view.remoteURLs != remoteURLs {
            remoteURLs = view.remoteURLs
            remoteAvatars = ownerAvatars()
            reloadVisible = true
        }
        if view.branchMap.generation != branchMap.generation { branchMap = view.branchMap }
        if view.worktreeMap.generation != worktreeMap.generation {
            // Other worktrees, other bits: `refreshWorktreeFade` lights the selected rows' again.
            if view.worktreeMap.paths != worktreeMap.paths { litWorktree = 0 }
            worktreeMap = view.worktreeMap
            reloadVisible = true
        }
        let wip = view.status.map(WorktreeChanges.init)
        if wip != wipChanges {
            wipChanges = wip
            reloadVisible = true
        }

        let old = log
        let new = view.log
        if new.generation != old.generation || new.syntheticRows.count != old.syntheticRows.count
            || new.commits.count < old.commits.count || new.hung.count < old.hung.count
        {
            // A new load (or a new layout): every row may have changed. A reload of a log already on screen keeps the
            // top visible row where it was (rows above it may have come or gone) and does not scroll to the selection.
            let start = DispatchTime.now().uptimeNanoseconds
            let anchor = old.rowCount > 0 && isPlaced ? scrollAnchor(table) : nil
            log = new
            // A load's first pages may need fewer lanes than the whole log: the column keeps the last log's until the
            // load completes, so it does not narrow and widen again on every refresh.
            logLanes = new.isComplete ? new.lanes : max(new.lanes, logLanes)
            hideStack()
            table.reloadData()
            if let anchor {
                restoreScroll(anchor, in: table)
                needsScroll = false
            }
            UITiming.graphReload(generation: new.generation, since: start)
            return
        }
        log = new
        if new.isComplete, !old.isComplete {
            logLanes = new.lanes
        } else if new.rows.count > old.rows.count {
            logLanes = max(logLanes, Self.lanes(of: new.rows[old.rows.count...]))
        }
        if new.rowCount > old.rowCount {
            // Later pages of the same load: the rows above are unchanged (a stash row comes with its base's page).
            table.insertRows(at: IndexSet(integersIn: old.rowCount..<rowCount), withAnimation: [])
        }
        if reloadVisible {
            let visible = table.rows(in: table.visibleRect)
            guard visible.length > 0 else { return }
            table.reloadData(forRowIndexes: IndexSet(integersIn: visible.location..<NSMaxRange(visible)),
                             columnIndexes: IndexSet(integersIn: 0..<table.numberOfColumns))
        }
    }

    private var rowCount: Int { log.rowCount }

    /// The most lanes one of `rows` draws in.
    private static func lanes(of rows: ArraySlice<GraphRow>) -> Int {
        rows.reduce(0) { max($0, $1.width) }
    }

    // MARK: Graph column width

    /// Fits the graph column to the log's lanes when their count or the row density changed: at least lane 0's node
    /// (`GraphMetrics.minColumnWidth`, every lane folded onto it), at most all of them (`GraphMetrics.width(lanes:)`,
    /// only the `trailing` gap right of the last lane), and the wanted width within that. AppKit's
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
            let dimmed = self.isDimmed(row: row)
            for column in columns {
                guard let cell = rowView.view(atColumn: column) as? GraphTextCellView, cell.isDimmed != dimmed
                else { continue }
                cell.isDimmed = dimmed
                cell.needsDisplay = true
            }
        }
    }

    /// Scrolls `row` to the middle of the rows' area when it is not wholly in it (under the column titles or the
    /// search bar counts as hidden).
    private func centerIfHidden(_ row: Int) {
        guard let table, let scroll = table.enclosingScrollView, row >= 0, row < table.numberOfRows else { return }
        let clip = scroll.contentView
        let top = clip.contentInsets.top
        let bottom = clip.contentInsets.bottom
        let rect = table.rect(ofRow: row)
        let bounds = clip.bounds
        guard rect.minY < bounds.minY + top || rect.maxY > bounds.maxY - bottom else { return }
        var origin = bounds.origin
        origin.y = rect.midY - (bounds.height + top - bottom) / 2
        clip.scroll(to: clip.constrainBoundsRect(NSRect(origin: origin, size: bounds.size)).origin)
        scroll.reflectScrolledClipView(clip)
    }

    /// The view's first position, once it has rows and its clip has its size (before, every row would count as hidden
    /// and the column titles' inset is still 0): where the tab's last view was (`GraphView.scrollPosition`) when the
    /// selection is the same and its anchor row is still there, else the top with the selection revealed.
    private func placeInitially() {
        guard !isPlaced, let view, let table, let scroll = table.enclosingScrollView, rowCount > 0 else { return }
        let clip = scroll.contentView
        guard clip.bounds.height > 0 else { return }
        isPlaced = true
        wanted = view.selection
        let top = clip.contentInsets.top
        var bounds = clip.bounds
        bounds.origin.y = -top
        var restored = false
        if let saved = view.scrollPosition, saved.selection == view.selection {
            if saved.atTop {
                restored = true
            } else if let anchor = saved.anchor, let row = row(of: anchor) {
                bounds.origin.y = table.rect(ofRow: row).minY - saved.offset - top
                restored = true
            }
        }
        clip.scroll(to: clip.constrainBoundsRect(bounds).origin)
        scroll.reflectScrolledClipView(clip)
        if restored {
            needsScroll = false
        } else if let row = table.selectedRowIndexes.first {
            centerIfHidden(row)
            needsScroll = false
        } else {
            // The selection's row is not loaded yet: `syncSelection` reveals it once it is.
            needsScroll = !view.selection.isEmpty
        }
        #if DEBUG
        UITiming.probe("graph-place", "restored=\(restored) inset=\(Int(top)) h=\(Int(clip.bounds.height)) "
            + "y=\(Int(clip.bounds.minY))")
        #endif
    }

    @objc private func clipResized(_ notification: Notification) {
        placeInitially()
        syncSpotlight(spotlightWanted)
    }

    // MARK: Spotlight

    /// The registry the WIP row's frame is registered with (`SpotlightTarget.wipRow`): the window's while this tab
    /// shows, nil while it is hidden or the view is gone.
    private weak var spotlight: SpotlightRegistry?
    /// The registry the last `update` asked for, applied on the next main-queue turn: registering reads the registry's
    /// observed target, which must stay out of the view's update.
    private weak var spotlightWanted: SpotlightRegistry?
    private var spotlightPending = false

    /// Registers the WIP row with `registry` (nil unregisters), or tells it the row may have moved; coalesced to one
    /// main-queue hop. Nothing while no registry is wanted or held, nor while the row is registered with `registry`
    /// and no spotlight shows (a spotlight that starts reads the row's frame from its provider).
    func syncSpotlight(_ registry: SpotlightRegistry?) {
        spotlightWanted = registry
        guard registry != nil || spotlight != nil, !spotlightPending else { return }
        if registry === spotlight, registry?.isShowing == false { return }
        spotlightPending = true
        DispatchQueue.main.async { [weak self] in self?.applySpotlight() }
    }

    private func applySpotlight() {
        spotlightPending = false
        guard spotlightWanted !== spotlight else {
            spotlight?.frameMayHaveChanged()
            return
        }
        spotlight?.unregister(.wipRow, owner: self)
        spotlight = spotlightWanted
        spotlight?.register(.wipRow, owner: self) { [weak self] in self?.wipRowFrame() }
    }

    /// The view is gone: its WIP row is no target any more.
    func detachSpotlight() {
        spotlightWanted = nil
        spotlight?.unregister(.wipRow, owner: self)
        spotlight = nil
    }

    /// The WIP row's visible part in window top-left coordinates (as `HeaderToolbar.frame(of:)`); nil without a WIP
    /// row, scrolled out of view, or out of a window.
    private func wipRowFrame() -> CGRect? {
        guard let table, let window = table.window, let content = window.contentView, let row = row(of: .wip)
        else { return nil }
        let rect = table.rect(ofRow: row).intersection(table.visibleRect)
        guard !rect.isEmpty else { return nil }
        var frame = content.convert(table.convert(rect, to: nil), from: nil)
        if !content.isFlipped { frame.origin.y = content.bounds.height - frame.maxY }
        return frame
    }

    /// Sends where the graph is (`GraphScrollPosition`) to `GraphView.onScroll`; nothing before its first position.
    func saveScroll() {
        guard isPlaced, let view, let table, let clip = table.enclosingScrollView?.contentView else { return }
        let visibleTop = clip.bounds.minY + clip.contentInsets.top
        var row = table.row(at: NSPoint(x: 1, y: max(visibleTop, 0) + 0.5))
        if row >= 0, table.rect(ofRow: row).minY < visibleTop - 0.5 { row += 1 }
        let anchor = row >= 0 && row < table.numberOfRows ? item(at: row) : nil
        let offset = anchor == nil ? 0 : table.rect(ofRow: row).minY - visibleTop
        view.onScroll(GraphScrollPosition(anchor: anchor, offset: offset, atTop: visibleTop <= 0.5,
                                          selection: view.selection))
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

    // MARK: Rows

    private func item(at row: Int) -> GraphItem? {
        switch log.entry(at: row) {
        case .synthetic(let synthetic, _):
            switch synthetic.kind {
            case .wip: return .wip
            case .stash: return .stash(synthetic.id)
            case .worktreeWIP: return .worktree(synthetic.id)
            }
        case .commit(let index): return .commit(log.commits[index].hash)
        case nil: return nil
        }
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
        guard column >= 0, let graphRow = log.graphRow(at: row) else { return 0 }
        let rect = table.rect(ofColumn: column)
        // From the node's center: the node hides the highlight's left end (no corner beside it).
        let nodeX = rect.minX + metrics.drawnX(lane: graphRow.lane, width: rect.width)
        return min(max(nodeX, rect.minX), rect.maxX)
    }

    /// Moves the highlight of the rows on screen (a column resize moved the graph column).
    func refreshHighlights() {
        guard let table else { return }
        table.enumerateAvailableRowViews { rowView, row in
            guard let rowView = rowView as? GraphRowView else { return }
            rowView.highlightStartX = self.highlightStartX(forRow: row, in: table)
            rowView.bandInset = self.metrics.bandInset
        }
    }

    func tableView(_ tableView: NSTableView, viewFor tableColumn: NSTableColumn?, row: Int) -> NSView? {
        guard let tableColumn, let column = GraphColumn(rawValue: tableColumn.identifier.rawValue),
              let entry = log.entry(at: row)
        else { return nil }
        let graphRow: GraphRow
        let commit: Commit?
        let synthetic: GraphSyntheticRow?
        switch entry {
        case .synthetic(let source, let drawn): (graphRow, commit, synthetic) = (drawn, nil, source)
        case .commit(let index): (graphRow, commit, synthetic) = (log.rows[index], log.commits[index], nil)
        }

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
            cell.color = graphRow.color
            cell.isFaded = isWorktreeFaded(row: row)
            cell.remoteAvatars = remoteAvatars
            cell.metrics = metrics
            // A reloaded row keeps its hover stack, made again from its new badges (a click on the stack selects
            // the row, which may reload it); a cell reused for another row gives it up.
            if row == stackRow {
                showStack(cell, row: row)
            } else if cell === coveredCell {
                hideStack()
            }
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
            cell.isFaded = isWorktreeFaded(row: row)
            cell.isSegmentFaded = { [weak self] owner in
                owner >= 0 && self?.isWorktreeFaded(commit: Int(owner)) == true
            }
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
            cell.textSize = metrics.textSize
            cell.changes = nil
            cell.isDimmed = isDimmed(row: row)
            // Every row sets it: a reused cell never keeps another row's pill.
            cell.openableWorktree = openableWorktree(synthetic)
            cell.isOpenButtonHovered = false
            if let commit {
                cell.text = commit.subject
                cell.tone = .primary
                cell.isItalic = false
            } else if synthetic?.kind == .stash {
                cell.text = stash(synthetic?.id)?.message ?? "Stash"
                cell.tone = .secondary
                cell.isItalic = true
            } else if let worktree = worktree(synthetic) {
                // This tab's own WIP row stays "// WIP"; another worktree's says whose it is.
                cell.text = "// WIP (on worktree \(worktree.name))"
                cell.changes = worktree.changes
                cell.tone = .secondary
                cell.isItalic = true
            } else {
                cell.text = "// WIP"
                cell.changes = wipChanges
                cell.tone = .primary
                cell.isItalic = true
            }
            cell.needsDisplay = true
            return cell
        case .author:
            let cell = reuse(tableView, column) { GraphTextCellView() }
            cell.textSize = metrics.textSize
            cell.compactTitle = column.title
            // 80 % of the node, kept even so it centers on a whole point in the (even) row height.
            cell.avatarDiameter = (metrics.nodeDiameter * 0.8 / 2).rounded() * 2
            cell.avatar = commit.flatMap { avatar(for: $0, in: tableView) }
            cell.text = commit?.authorName ?? ""
            cell.changes = nil
            cell.isDimmed = isDimmed(row: row)
            cell.tone = .secondary
            cell.isItalic = false
            cell.needsDisplay = true
            return cell
        case .date:
            let cell = reuse(tableView, column) { GraphTextCellView() }
            cell.textSize = metrics.textSize
            // Formatted only for the rows on screen.
            let date = commit?.authorDate ?? (synthetic?.kind == .stash ? stash(synthetic?.id)?.date : nil)
            cell.text = date.map(formatter.string(from:)) ?? ""
            cell.changes = nil
            cell.isDimmed = isDimmed(row: row)
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

    /// An avatar arrived (redraw the visible nodes and author cells of its author) or the mode changed (redraw every
    /// visible one).
    @objc private func avatarsChanged(_ notification: Notification) {
        guard let table else { return }
        let owner = notification.userInfo?[AvatarStore.emailKey] as? String
        if owner == nil || owner?.hasPrefix("owner:") == true { refreshRemoteAvatars(table) }
        let column = table.column(withIdentifier: GraphColumn.graph.identifier)
        let authorColumn = table.column(withIdentifier: GraphColumn.author.identifier)
        let visible = table.rows(in: table.visibleRect)
        guard column >= 0, visible.length > 0 else { return }
        let changed = notification.userInfo?[AvatarStore.emailKey] as? String
        for row in visible.location..<NSMaxRange(visible) {
            guard case .commit(let index) = log.entry(at: row) else { continue }
            let commit = log.commits[index]
            if let changed, !AvatarStore.matches(email: commit.authorEmail, name: commit.authorName, changed: changed) {
                continue
            }
            let image = avatar(for: commit, in: table)
            if authorColumn >= 0,
               let cell = table.view(atColumn: authorColumn, row: row, makeIfNecessary: false) as? GraphTextCellView {
                cell.avatar = image
                cell.needsDisplay = true
            }
            if !commit.isMerge,
               let cell = table.view(atColumn: column, row: row, makeIfNecessary: false) as? GraphCellView {
                cell.avatar = image
                cell.needsDisplay = true
            }
        }
    }

    /// The logo of each remote's owner that is loaded (`AvatarStore.ownerAvatar` starts the others' loads), at the
    /// sidebar's size so both share one download.
    private func ownerAvatars() -> [String: NSImage] {
        let scale = table?.window?.backingScaleFactor ?? NSScreen.main?.backingScaleFactor ?? 2
        let pixels = Int((16 * scale).rounded(.up))
        return remoteURLs.compactMapValues { url in
            GitHubClient.repository(fromRemoteURL: url).flatMap {
                AvatarStore.shared.ownerAvatar(of: $0, pixels: pixels)
            }
        }
    }

    /// A remote owner's logo arrived, or the avatar mode changed: the visible badges (and the hover stack) redraw.
    private func refreshRemoteAvatars(_ table: NSTableView) {
        let avatars = ownerAvatars()
        guard avatars != remoteAvatars else { return }
        remoteAvatars = avatars
        let column = table.column(withIdentifier: GraphColumn.refs.identifier)
        let visible = table.rows(in: table.visibleRect)
        if column >= 0 {
            for row in visible.location..<NSMaxRange(visible) {
                guard let cell = table.view(atColumn: column, row: row, makeIfNecessary: false) as? RefBadgeCellView
                else { continue }
                cell.remoteAvatars = avatars
                cell.needsDisplay = true
            }
        }
        stackOverlay?.remoteAvatars = avatars
        stackOverlay?.needsDisplay = true
    }

    private func stash(_ hash: String?) -> Stash? {
        log.stashes.first { $0.hash == hash }
    }

    /// A text cell's dimming: a row the search does not match, or another worktree's faded row.
    private func isDimmed(row: Int) -> Bool {
        isWorktreeFaded(row: row) || dimming.isDimmed(row: row, in: log)
    }

    /// A row of a worktree that is not lit, faded so it does not read as the lit one's: another worktree's WIP row (this
    /// one's while another is lit), and the commits from where they fork off the lit worktree's history (`WorktreeMap`).
    private func isWorktreeFaded(row: Int) -> Bool {
        switch log.entry(at: row) {
        case .commit(let index): isWorktreeFaded(commit: index)
        case .synthetic(let synthetic, _) where synthetic.kind == .worktreeWIP:
            worktreeMap.bit(of: synthetic.id) & litBit == 0
        case .synthetic(let synthetic, _) where synthetic.kind == .wip: litWorktree != 0
        default: false
        }
    }

    /// `log.commits[index]` is a worktree's but not the lit one's; its lines to its parents fade with it.
    private func isWorktreeFaded(commit index: Int) -> Bool {
        let mask = worktreeMap.mask(at: index, in: log)
        return mask != 0 && mask & litBit == 0
    }

    /// The worktrees of `row` (`WorktreeMap` bits): a commit's, or a WIP row's own.
    private func worktreeBits(row: Int) -> UInt64 {
        switch log.entry(at: row) {
        case .commit(let index): worktreeMap.mask(at: index, in: log)
        case .synthetic(let synthetic, _) where synthetic.kind == .worktreeWIP: worktreeMap.bit(of: synthetic.id)
        case .synthetic(let synthetic, _) where synthetic.kind == .wip: worktreeMap.head
        default: 0
        }
    }

    /// Lights one worktree of the selected rows and fades every other one (this one too), redrawing the cells the table
    /// has made (on screen and just around it) when that changed. The lit worktree stays while a selected row is on it;
    /// else this one when a selected row is on it or none is, else the first. In the click's frame: only the map.
    private func refreshWorktreeFade() {
        guard let table else { return }
        let bits = table.selectedRowIndexes.reduce(UInt64(0)) { $0 | worktreeBits(row: $1) }
        let lit: UInt64 =
            if litWorktree != 0, bits & litWorktree != 0 { litWorktree }
            else if bits == 0 || bits & worktreeMap.head != 0 { 0 }
            else { bits & (0 &- bits) }
        guard lit != litWorktree else { return }
        litWorktree = lit
        let graph = table.column(withIdentifier: GraphColumn.graph.identifier)
        let refs = table.column(withIdentifier: GraphColumn.refs.identifier)
        table.enumerateAvailableRowViews { rowView, row in
            let faded = self.isWorktreeFaded(row: row)
            if graph >= 0, let cell = rowView.view(atColumn: graph) as? GraphCellView {
                // Lines passing by may be another row's: every graph cell redraws.
                cell.isFaded = faded
                cell.needsDisplay = true
            }
            if refs >= 0, let cell = rowView.view(atColumn: refs) as? RefBadgeCellView, cell.isFaded != faded {
                cell.isFaded = faded
                cell.needsDisplay = true
            }
        }
        refreshDimming()
    }

    /// The other worktree of a worktree WIP row.
    private func worktree(_ synthetic: GraphSyntheticRow?) -> WorktreeInfo? {
        guard let synthetic, synthetic.kind == .worktreeWIP else { return nil }
        return log.worktrees.first { $0.path == synthetic.id }
    }

    /// The path of the worktree a row opens (its "Open in New Tab"): another worktree's WIP row, not a prunable one.
    private func openableWorktree(_ synthetic: GraphSyntheticRow?) -> String? {
        guard let info = worktree(synthetic), !info.isCurrent, !info.worktree.isPrunable else { return nil }
        return info.path
    }

    // MARK: Open Worktree pill

    /// Lights the Open Worktree pill under the pointer, as `RowTextButtonStyle` on hover.
    func hoverOpenButton(at point: NSPoint?) {
        let cell = point.flatMap { openButtonCell(at: $0) }
        if litOpenButton !== cell { litOpenButton?.isOpenButtonHovered = false }
        cell?.isOpenButtonHovered = true
        litOpenButton = cell
    }

    /// A click on the Open Worktree pill: opens that worktree's tab, as a double-click on its row.
    func openWorktree(at point: NSPoint) -> Bool {
        guard let path = openButtonCell(at: point)?.openableWorktree else { return false }
        hoverOpenButton(at: nil)
        view?.onActivate(.worktree(path), nil)
        return true
    }

    /// The message cell at `point` (in the table) when `point` is on its Open Worktree pill.
    private func openButtonCell(at point: NSPoint) -> GraphTextCellView? {
        guard let table else { return nil }
        let row = table.row(at: point)
        let column = table.column(withIdentifier: GraphColumn.message.identifier)
        guard row >= 0, column >= 0,
              let cell = table.view(atColumn: column, row: row, makeIfNecessary: false) as? GraphTextCellView,
              cell.openButtonRect?.contains(cell.convert(point, from: table)) == true
        else { return nil }
        return cell
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
        refreshWorktreeFade()
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
        guard case .commit(let index) = log.entry(at: row) else { return nil }
        let hash = log.commits[index].hash
        let hasBranch = badges[hash]?.contains { if case .branch = $0.kind { true } else { false } } ?? false
        guard !hasBranch, let name = branchMap.branch(at: index, in: log) else { return nil }
        let isLocal = refs?.localBranches.contains { $0.name == name } ?? false
        var label: String?
        var remoteName: String?
        if !isLocal, let refs, let remote = refs.remoteBranches.first(where: { $0.name == name }) {
            label = RefBadge.remoteLabel(of: remote, singleRemote: RefBadge.singleRemote(refs, remotes: remotes))
            remoteName = remote.remote
        }
        return Ghost(row: row, hash: hash, badge: RefBadge(
            kind: .branch(isLocal: isLocal, isRemote: !isLocal, isHead: false), name: name, label: label,
            isGhost: true, remote: remoteName,
            isOtherWorktree: isLocal && otherWorktreeBranches.contains("refs/heads/" + name)))
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

    /// A click: the selection already changed at mouse down; a click that did not change it reports nothing new.
    @objc func clicked(_ sender: Any?) {
        reportSelection()
    }

    /// Activates the double-clicked row (the hook: checkout, or another worktree's tab); the first click of the pair has
    /// already selected it.
    @objc func doubleClicked(_ sender: Any?) {
        guard let item = item(at: clickedRow) else { return }
        view?.onActivate(item, (table as? GraphTableView)?.mouseDownPoint.flatMap { badge(at: $0) })
    }

    /// Selects the rows of `selection` when the table shows another selection (a parent jump, the default selection,
    /// rows moved by a reload), and centres a new one when it is off screen. `reported` takes it first, so it is not sent back.
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
        // Before the first position, `placeInitially` reveals it.
        if needsScroll, isPlaced, let first = rows.first {
            centerIfHidden(first)
            needsScroll = false
        }
    }

    private func row(of item: GraphItem) -> Int? {
        switch item {
        case .wip:
            return log.row { $0.kind == .wip }
        case .stash(let hash):
            return log.row { $0.kind == .stash && $0.id == hash }
        case .commit(let hash):
            // The log's index first: a search move to a commit far down a 50,000-commit log stays instant.
            let index = log.commitIndex[hash].flatMap {
                log.commits.indices.contains($0) && log.commits[$0].hash == hash ? $0 : nil
            }
                ?? log.commits.firstIndex { $0.hash == hash }
            return index.map { log.row(ofCommit: $0) }
        case .worktree(let path):
            return log.row { $0.kind == .worktreeWIP && $0.id == path }
        }
    }

    /// Another worktree's row is reported alone (its changes); among several rows the session leaves it out.
    private func reportSelection() {
        guard let table, !isUpdating else { return }
        let items = table.selectedRowIndexes.compactMap(item(at:))
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
        guard let view, let item = item(at: routedRow(at: point)) else { return nil }
        let entries = view.menuEntries(item, badge(at: point))
        return entries.isEmpty ? nil : MenuBuilder.menu(entries)
    }

    /// Opens the pull request whose chip is at `point` (in the table); false when there is none.
    func openPullRequest(at point: NSPoint) -> Bool {
        guard let table, let view, let cell = badgeView(at: point),
              let pull = cell.pullRequest(at: cell.convert(point, from: table))
        else { return false }
        view.onOpenPullRequest(pull.number)
        return true
    }

    /// True when a drag at `point` (in the table) drags a branch badge: on one, but not on its pull request chip.
    func canDragBadge(at point: NSPoint) -> Bool {
        guard let table, let cell = badgeView(at: point), cell.pullRequest(at: cell.convert(point, from: table)) == nil
        else { return false }
        return badge(at: point)?.sidebarItem?.branchName != nil
    }

    /// The badge drawn at `point` (in the table): in the hover stack when it is on one of its badges.
    private func badge(at point: NSPoint) -> RefBadge? {
        guard let table, let cell = badgeView(at: point) else { return nil }
        return cell.badge(at: cell.convert(point, from: table))
    }

    // MARK: Drag and drop

    /// Only a branch badge drags (its row would otherwise start a row drag, which the graph does not have): a drag
    /// anywhere else keeps the table's own drag-to-select.
    func tableView(_ tableView: NSTableView, pasteboardWriterForRow row: Int) -> (any NSPasteboardWriting)? {
        // The row under the press, or the stack's own row (a drag of a stacked badge): one item for the drag.
        guard dragged == nil, let point = (tableView as? GraphTableView)?.mouseDownPoint,
              row == tableView.row(at: point) || row == routedRow(at: point),
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
              let cell = badgeView(at: point)
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
        tableView.setDropRow(routedRow(at: point), dropOperation: .on)
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

    // MARK: Badge stack

    /// Shows the hovered row's badges whole, one under the other, while the pointer is on its refs
    /// cell or on the stack's badges, when the cell does not show them all whole; the badge under the pointer is lit.
    /// The table keeps the events and routes those on a stacked badge to it (`badgeView`, `routedRow`): a click
    /// selects the stack's row, a right-click opens the badge's menu, a branch badge drags and takes drops.
    func hoverRefs(at point: NSPoint?) {
        guard let table, let point else { return hideStack() }
        if let stackOverlay, stackOverlay.superview != nil {
            let index = stackIndex(at: point)
            if index != nil || table.row(at: point) == stackRow && cell(at: point) != nil {
                stackOverlay.hovered = index.flatMap { stackOverlay.badges[$0].isGhost ? nil : $0 }
                return
            }
        }
        guard let cell = cell(at: point), !cell.showsAllBadges else { return hideStack() }
        hideStack()
        showStack(cell, row: table.row(at: point))
        stackOverlay?.hovered = stackIndex(at: point)
    }

    /// Lays the stack over `row`, whose refs cell is `cell` (also a cell just made for it by a reload: its badges may
    /// have changed), and hides that cell's own badges.
    private func showStack(_ cell: RefBadgeCellView, row: Int) {
        guard let table else { return }
        let column = table.column(withIdentifier: GraphColumn.refs.identifier)
        guard column >= 0, row >= 0, row < table.numberOfRows else { return hideStack() }
        let cellRect = table.frameOfCell(atColumn: column, row: row)
        let overlay = stackOverlay ?? RefBadgeCellView()
        if row != stackRow || overlay.badges != cell.badges { overlay.hovered = nil }
        overlay.badges = cell.badges
        overlay.color = cell.color
        overlay.isFaded = cell.isFaded
        overlay.remoteAvatars = cell.remoteAvatars
        overlay.metrics = metrics
        let size = overlay.stackSize(rowHeight: cellRect.height, lineEnd: cellRect.width)
        // Near the bottom of the view the stack grows up from the row, so it is not cut.
        let visible = table.visibleRect
        let bottom = visible.maxY - (table.enclosingScrollView?.contentInsets.bottom ?? 0)
        let upward = cellRect.minY + size.height > bottom && cellRect.maxY - size.height >= visible.minY
        overlay.stack = RefBadgeCellView.Stack(rowHeight: cellRect.height, upward: upward, lineEnd: cellRect.width)
        overlay.frame = CGRect(x: cellRect.minX, y: upward ? cellRect.maxY - size.height : cellRect.minY,
                               width: size.width, height: size.height)
        // Above the row views, also those added since it was last shown.
        table.addSubview(overlay, positioned: .above, relativeTo: nil)
        overlay.needsDisplay = true
        if coveredCell !== cell { coveredCell?.isCovered = false }
        cell.isCovered = true
        coveredCell = cell
        stackRow = row
        stackOverlay = overlay
    }

    func hideStack() {
        stackOverlay?.removeFromSuperview()
        stackOverlay?.hovered = nil
        coveredCell?.isCovered = false
        coveredCell = nil
        stackRow = -1
    }

    /// The stack's badge at `point` (in the table), when the stack is shown and `point` is on one of its badges.
    private func stackIndex(at point: NSPoint) -> Int? {
        guard let table, let overlay = stackOverlay, overlay.superview != nil else { return nil }
        return overlay.badgeIndex(at: overlay.convert(point, from: table))
    }

    /// The view whose badges are at `point` (in the table): the stack on one of its badges, else the refs cell.
    private func badgeView(at point: NSPoint) -> RefBadgeCellView? {
        stackIndex(at: point) != nil ? stackOverlay : cell(at: point)
    }

    /// The row an event at `point` (in the table) is for: the stack's row on one of its badges.
    private func routedRow(at point: NSPoint) -> Int {
        stackIndex(at: point) != nil ? stackRow : table?.row(at: point) ?? -1
    }

    /// A mouse down (or a right-click) at `point`, with the event's `modifiers`: on a stacked badge it is for the
    /// stack's row until `endPress`. On the stack's own refs cell, off its badges, the stack stays (as for a hover), so
    /// the badges it covers stay hidden and answer no click, menu or drag; the row selects as usual. Elsewhere the
    /// stack goes away.
    func beginPress(at point: NSPoint, modifiers: NSEvent.ModifierFlags) {
        dragged = nil
        pressRow = nil
        if stackIndex(at: point) != nil {
            pressRow = (row: table?.row(at: point) ?? -1, stack: stackRow,
                        selection: table?.selectedRowIndexes ?? IndexSet(), modifiers: modifiers)
        } else if table?.row(at: point) != stackRow || cell(at: point) == nil {
            hideStack()
        }
    }

    func endPress() { pressRow = nil }

    /// The clicked row, the stack's own for a click on a stacked badge.
    private var clickedRow: Int { pressRow?.stack ?? table?.clickedRow ?? -1 }

    /// A press on a stacked badge selects the stack's row, not the row under it: with Command it toggles that row in
    /// the selection the press began with, with Shift it adds it, else it selects it alone. The table may ask again
    /// as the pointer drags, so the answer comes from the press's start, never from the current selection.
    func tableView(_ tableView: NSTableView, selectionIndexesForProposedSelection proposed: IndexSet) -> IndexSet {
        guard let pressRow, pressRow.row != pressRow.stack else { return proposed }
        guard pressRow.row >= 0 else { return IndexSet(integer: pressRow.stack) }
        var selection = pressRow.selection
        if pressRow.modifiers.contains(.command) {
            if selection.remove(pressRow.stack) == nil { selection.insert(pressRow.stack) }
            return selection
        }
        if pressRow.modifiers.contains(.shift) { return selection.union(IndexSet(integer: pressRow.stack)) }
        return IndexSet(integer: pressRow.stack)
    }

    @objc private func scrolled(_ notification: Notification) {
        hideStack()
        hoverOpenButton(at: nil)
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
        hideStack()
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

/// Over the graph's header while branches are left out: "2 hidden · Show All", "Solo · Show All" or both; a click shows
/// every branch (`RepoSession.showAll`).
struct GraphVisibilityChip: View {
    let session: RepoSession

    var body: some View {
        let hidden = session.hiddenCount
        if hidden > 0 || session.isSoloActive {
            let summary = [hidden > 0 ? "\(hidden) hidden" : nil, session.isSoloActive ? "Solo" : nil]
                .compactMap(\.self).joined(separator: " · ")
            Button { session.showAll() } label: {
                Text("\(summary) · \(Text("Show All").foregroundStyle(Color.accentColor))")
                    .font(.caption)
            }
            .buttonStyle(RaisedButtonStyle(height: 22, horizontalPadding: 10))
            .help("Show every branch in the graph")
            .padding(.top, 2)
            .padding(.trailing, 8)
        }
    }
}
