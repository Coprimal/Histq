// Pane A or B of the conflict editor: that side's whole file in an NSTableView with fixed rows (18 pt at the default code
// font size) that never wrap.
// Lines inside a conflict get one checkbox in the gutter (the pane's header checkbox takes the whole side) and, right of
// it, an edge bar and a band over the number and the text (A blue, B gold; stronger once ticked). ⌘C copies the selected lines whole.
import AppKit
import HistqCore
import SwiftUI

/// Sizes shared by the three panes: one line height everywhere, so a scroll offset maps to a line in each pane.
enum ConflictLayout {
    @MainActor static var lineHeight: CGFloat { DiffLayout.lineHeight }
    /// The line checkbox's column, never tinted: a conflict line's edge bar starts right after it.
    static let checkboxWidth: CGFloat = 20
    static let barWidth: CGFloat = 3
}

/// One side's lines and checkboxes. `revision` changes with every tick or edit (the rows redraw); `loadID` with every
/// load (the rows reload), as a new code font size does.
struct ConflictLinePane: NSViewRepresentable {
    let side: ThreeWayMerge.Side
    /// The side's lines without their line breaks.
    let lines: [String]
    let merge: ThreeWayMerge
    let revision: Int
    let loadID: Int
    let sync: ScrollSync
    var onTickLines: @MainActor (Bool, [Int]) -> Void = { _, _ in }
    @AppStorage(PrefKey.codeFontSize.rawValue, store: Preferences.defaults) private(set) var fontSize = 12.0
    @Environment(\.tabIsShown) private var tabIsShown

    func makeCoordinator() -> ConflictPaneController { ConflictPaneController() }

    func makeNSView(context: Context) -> NSScrollView {
        let table = ConflictTableView()
        table.style = .plain
        table.backgroundColor = .clear
        table.gridStyleMask = []
        table.intercellSpacing = .zero
        table.usesAutomaticRowHeights = false
        table.rowHeight = ConflictLayout.lineHeight
        table.allowsMultipleSelection = true
        table.allowsEmptySelection = true
        table.allowsColumnReordering = false
        table.allowsColumnResizing = false
        table.columnAutoresizingStyle = .noColumnAutoresizing
        table.focusRingType = .none
        table.headerView = nil
        let column = NSTableColumn(identifier: NSUserInterfaceItemIdentifier("line"))
        column.resizingMask = []
        table.addTableColumn(column)

        let scroll = NSScrollView()
        scroll.documentView = table
        scroll.drawsBackground = false
        scroll.borderType = .noBorder
        scroll.hasVerticalScroller = true
        // Lines never wrap: a long line scrolls sideways.
        scroll.hasHorizontalScroller = true
        scroll.autohidesScrollers = true
        scroll.isHidden = !tabIsShown

        context.coordinator.attach(table)
        sync.register(scroll, as: side == .a ? .a : .b)
        return scroll
    }

    func updateNSView(_ scroll: NSScrollView, context: Context) {
        if scroll.isHidden == tabIsShown { scroll.isHidden = !tabIsShown }
        context.coordinator.update(self)
    }
}

/// The pane's table: its one column is as wide as the longest line or the card, whichever is wider.
final class ConflictTableView: NSTableView {
    var contentWidth: CGFloat = 0 {
        didSet { if contentWidth != oldValue { tile() } }
    }
    weak var controller: ConflictPaneController?

    override func tile() {
        super.tile()
        guard let clip = enclosingScrollView?.contentView, let column = tableColumns.first else { return }
        let width = max(contentWidth, clip.bounds.width)
        if abs(column.width - width) > 0.5 { column.width = width }
    }

    @objc func copy(_ sender: Any?) {
        controller?.copySelection()
    }
}

/// What a row shows about the conflicts: nothing outside them; inside one, its index and the checkbox state.
struct ConflictLineState: Equatable {
    /// The conflict (0-based) the line belongs to, nil outside any.
    var conflict: Int?
    var isTicked = false
}

/// The table's data source and delegate. Reloads for a new load; a tick only reconfigures the rows on screen.
@MainActor
final class ConflictPaneController: NSObject, NSTableViewDataSource, NSTableViewDelegate {
    private weak var table: ConflictTableView?
    private var view: ConflictLinePane?
    private var shown: (loadID: Int, revision: Int, fontSize: Double)?
    /// The conflict index of each region that is a conflict.
    private var conflictOfRegion: [Int: Int] = [:]
    private var numberWidth: CGFloat = 40

    private static let cellID = NSUserInterfaceItemIdentifier("conflictLine")
    private static let rowID = NSUserInterfaceItemIdentifier("conflictRow")

    func attach(_ table: ConflictTableView) {
        self.table = table
        table.controller = self
        table.dataSource = self
        table.delegate = self
    }

    func update(_ view: ConflictLinePane) {
        self.view = view
        guard let table else { return }
        DiffLayout.use(view.fontSize)
        if shown?.loadID != view.loadID || shown?.fontSize != view.fontSize {
            shown = (view.loadID, view.revision, view.fontSize)
            table.rowHeight = ConflictLayout.lineHeight
            conflictOfRegion = Dictionary(
                uniqueKeysWithValues: view.merge.conflictRegions.enumerated().map { ($0.element, $0.offset) })
            let digits = max(3, String(view.lines.count).count)
            numberWidth = CGFloat(digits) * DiffLayout.charWidth + 12
            let longest = view.lines.reduce(0) { longest, line in
                max(longest, line.utf16.count + line.utf16.count { $0 == 0x09 } * (DiffLayout.tabWidth - 1))
            }
            table.reloadData()
            table.contentWidth = textX + CGFloat(longest) * DiffLayout.charWidth + 24
        } else if shown?.revision != view.revision {
            shown = (view.loadID, view.revision, view.fontSize)
            let visible = table.rows(in: table.visibleRect)
            guard visible.length > 0 else { return }
            table.reloadData(forRowIndexes: IndexSet(integersIn: visible.location..<NSMaxRange(visible)),
                             columnIndexes: IndexSet(integer: 0))
        }
    }

    private var textX: CGFloat { ConflictLayout.checkboxWidth + 4 + numberWidth + 10 }

    /// Where `row` sits among the conflicts of this side, with its checkbox state.
    private func state(of row: Int) -> ConflictLineState {
        guard let view else { return ConflictLineState() }
        let merge = view.merge
        let pane: ThreeWayMerge.Pane = view.side == .a ? .a : .b
        guard let index = merge.region(containing: row, in: pane), let k = conflictOfRegion[index] else {
            return ConflictLineState()
        }
        let lines = view.side == .a ? merge.regions[index].a : merge.regions[index].b
        guard lines.contains(row) else { return ConflictLineState() }
        return ConflictLineState(conflict: k, isTicked: merge.isTicked(view.side, line: row))
    }

    // MARK: Data

    func numberOfRows(in tableView: NSTableView) -> Int { view?.lines.count ?? 0 }

    func tableView(_ tableView: NSTableView, rowViewForRow row: Int) -> NSTableRowView? {
        tableView.makeView(withIdentifier: Self.rowID, owner: nil) as? DiffRowView ?? {
            let view = DiffRowView()
            view.identifier = Self.rowID
            return view
        }()
    }

    func tableView(_ tableView: NSTableView, viewFor tableColumn: NSTableColumn?, row: Int) -> NSView? {
        guard let view, view.lines.indices.contains(row) else { return nil }
        let cell = tableView.makeView(withIdentifier: Self.cellID, owner: nil) as? ConflictLineCellView ?? {
            let cell = ConflictLineCellView()
            cell.identifier = Self.cellID
            return cell
        }()
        let state = state(of: row)
        cell.configure(
            number: row + 1, text: view.lines[row], side: view.side, state: state, numberWidth: numberWidth,
            textX: textX
        ) { [weak self] in
            self?.toggle(row: row)
        }
        return cell
    }

    /// A checkbox click: the line's tick flips.
    private func toggle(row: Int) {
        guard let view else { return }
        let state = state(of: row)
        guard state.conflict != nil else { return }
        view.onTickLines(!state.isTicked, [row])
    }

    /// The selected lines, whole, one per line.
    func copySelection() {
        guard let table, let view else { return }
        let lines = table.selectedRowIndexes.compactMap { view.lines.indices.contains($0) ? view.lines[$0] : nil }
        guard !lines.isEmpty else { return }
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(lines.joined(separator: "\n") + "\n", forType: .string)
    }
}

/// A line of pane A or B: the line checkbox, then inside a conflict its edge bar and band (over the number and the
/// text), the number, the text.
final class ConflictLineCellView: NSView {
    private let lineBox = NSButton(checkboxWithTitle: "", target: nil, action: nil)
    private var number = 0
    private var text = ""
    private var side: ThreeWayMerge.Side = .a
    private var state = ConflictLineState()
    private var numberWidth: CGFloat = 40
    private var textX: CGFloat = 80
    private var onToggle: (() -> Void)?

    override var isFlipped: Bool { true }
    override var isOpaque: Bool { false }

    override init(frame: NSRect) {
        super.init(frame: frame)
        lineBox.controlSize = .small
        lineBox.target = self
        lineBox.action = #selector(linePressed)
        lineBox.setAccessibilityLabel("Take this line")
        addSubview(lineBox)
        setAccessibilityElement(true)
        setAccessibilityRole(.staticText)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) is not used") }

    func configure(number: Int, text: String, side: ThreeWayMerge.Side, state: ConflictLineState, numberWidth: CGFloat,
                   textX: CGFloat, onToggle: @escaping () -> Void)
    {
        self.number = number
        self.text = text
        self.side = side
        self.state = state
        self.numberWidth = numberWidth
        self.textX = textX
        self.onToggle = onToggle
        lineBox.isHidden = state.conflict == nil
        lineBox.state = state.isTicked ? .on : .off
        setAccessibilityLabel("\(number): \(text)")
        needsLayout = true
        needsDisplay = true
    }

    override func layout() {
        super.layout()
        let size = lineBox.intrinsicContentSize
        // Centered in its column, left of the edge bar.
        lineBox.frame = NSRect(x: max(0, (ConflictLayout.checkboxWidth - size.width) / 2),
                               y: (bounds.height - size.height) / 2, width: size.width, height: size.height)
    }

    @objc private func linePressed() { onToggle?() }

    /// The attributes at one code font size.
    @MainActor
    private struct Style {
        let text: [NSAttributedString.Key: Any]
        let number: [NSAttributedString.Key: Any]

        private static var styles: [CGFloat: Style] = [:]

        /// The attributes at the current code font size, made once per size.
        static var current: Style {
            let metrics = DiffLayout.metrics
            if let style = styles[metrics.size] { return style }
            let paragraph = NSMutableParagraphStyle()
            paragraph.tabStops = []
            paragraph.defaultTabInterval = CGFloat(DiffLayout.tabWidth) * metrics.charWidth
            paragraph.lineBreakMode = .byClipping
            let numberParagraph = NSMutableParagraphStyle()
            numberParagraph.alignment = .right
            let style = Style(
                text: [.font: metrics.font, .foregroundColor: Palette.diffText, .paragraphStyle: paragraph],
                number: [.font: metrics.numberFont, .foregroundColor: Palette.diffLineNumber,
                         .paragraphStyle: numberParagraph])
            styles[metrics.size] = style
            return style
        }
    }

    override func draw(_ dirtyRect: NSRect) {
        let height = bounds.height
        if state.conflict != nil {
            let isA = side == .a
            let fill = state.isTicked
                ? (isA ? Palette.conflictATickedFill : Palette.conflictBTickedFill)
                : (isA ? Palette.conflictAFill : Palette.conflictBFill)
            let x = ConflictLayout.checkboxWidth
            fill.setFill()
            NSRect(x: x, y: 0, width: max(0, bounds.width - x), height: height).fill(using: .sourceOver)
            (isA ? Palette.conflictA : Palette.conflictB).setFill()
            NSRect(x: x, y: 0, width: ConflictLayout.barWidth, height: height).fill()
        }
        let style = Style.current
        let numberX = ConflictLayout.checkboxWidth + 4
        let numberY = (height - DiffLayout.numberFont.boundingRectForFont.height) / 2
        NSString(string: "\(number)").draw(
            in: NSRect(x: numberX, y: numberY, width: numberWidth - 6, height: height), withAttributes: style.number)
        let textY = (height - (DiffLayout.font.ascender - DiffLayout.font.descender)) / 2
        NSAttributedString(string: text, attributes: style.text).draw(at: NSPoint(x: textX, y: textY))
    }
}
