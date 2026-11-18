// The lines of one side of a file's diff: an NSTableView whose rows are one line high, or as high as their wrapped text
// (Wrap Lines). Each line row has the old and new line numbers, a `+`/`−` gutter, a green or red band, a stronger mark
// on the changed part of a replaced line, and syntax colors; in Split a row has the old line on the left and the new
// one on the right. Each hunk starts with a header row whose buttons stage, unstage, discard or revert the hunk, or only
// its selected lines (none while whitespace is ignored). ⌘C copies the selected lines whole; Esc goes back to the graph.
//
// The rows (with their tokens) are built off the main actor when the diff loads: the table only draws the rows on
// screen, so its cost does not grow with the file.
import AppKit
import HistqCore
import SwiftUI

/// Which changes a diff section holds, and what its hunk buttons can do with them.
enum DiffSide: Hashable, Sendable {
    /// The working tree against the index.
    case unstaged
    /// The index against HEAD.
    case staged
    /// A commit or a stash against its first parent: read-only.
    case commit
    /// A file git does not track: its lines, read-only (the WIP panel stages it whole).
    case untracked
    /// A file a commit did not change (its Files card's "View all files"): its lines at that commit, read-only.
    case file

    var title: String {
        switch self {
        case .unstaged: "Unstaged"
        case .staged: "Staged"
        case .commit: "Changes"
        case .untracked: "Untracked"
        case .file: "File"
        }
    }

    var systemImage: String {
        switch self {
        case .unstaged: "doc.badge.ellipsis"
        case .staged: "tray.full"
        case .commit: "doc.text"
        case .untracked: "questionmark.square.dashed"
        case .file: "doc"
        }
    }

    /// The hunk header buttons, in their order.
    var actions: [PatchBuilder.Action] {
        switch self {
        case .unstaged: [.stage, .discard]
        case .staged: [.unstage]
        case .commit, .untracked, .file: []
        }
    }
}

/// One row of a diff table: a hunk header or a line, with its tokens and its intraline mark ready to draw.
struct DiffRow: Sendable {
    enum Kind: Sendable, Equatable {
        /// The header of hunk `index`.
        case hunk(Int)
        case context
        case added
        case removed
    }

    let kind: Kind
    /// The line in its `FileDiff` (what a patch selects); nil for a hunk header, an untracked file's line and a
    /// combined diff's line (read-only).
    let id: DiffLineID?
    let oldLine: Int?
    let newLine: Int?
    /// The line without its line break (a CR before it is dropped too), or the hunk header's text.
    let text: String
    let tokens: [SyntaxToken]
    /// The changed part of a replaced line (UTF-16 range of `text`), when a removed line and an added line pair up.
    var emphasis: NSRange?

    var isLine: Bool {
        if case .hunk = kind { false } else { true }
    }

    var isChange: Bool { kind == .added || kind == .removed }
}

/// One row of the table: a unified row (a line or a hunk header), or in Split a pair of an old line (left) and a new
/// line (right), either missing where the other side has more lines. A context line is the same row on both sides.
enum DiffTableRow: Sendable {
    case single(DiffRow)
    case pair(old: DiffRow?, new: DiffRow?)

    /// The hunk whose header this row is.
    var hunk: Int? {
        if case .single(let row) = self, case .hunk(let index) = row.kind { index } else { nil }
    }

    var isLine: Bool { hunk == nil }

    /// The lines the row shows (a context line once).
    var lines: [DiffRow] {
        switch self {
        case .single(let row): row.isLine ? [row] : []
        case .pair(let old, let new): old?.kind == .context ? [old].compactMap { $0 } : [old, new].compactMap { $0 }
        }
    }

    var isChange: Bool { lines.contains(where: \.isChange) }
}

/// One card of a file's diff: the changes of one side, as rows for both modes.
struct DiffSection: Sendable, Identifiable {
    let side: DiffSide
    /// git's diff with its usual context (Diff mode); nil for an untracked file.
    let diff: FileDiff?
    /// The same diff with the whole file as context (Full file mode); nil when git gave none.
    let full: FileDiff?
    let rows: [DiffRow]
    let fullRows: [DiffRow]
    /// `rows` side by side (Split); a file's own lines (untracked, unchanged) stay one column.
    let splitRows: [DiffTableRow]
    let additions: Int
    let deletions: Int

    var id: DiffSide { side }
    var isBinary: Bool { diff?.isBinary == true }

    func rows(_ mode: DiffMode) -> [DiffRow] { mode == .full ? fullRows : rows }

    /// The table's rows in `mode`.
    func tableRows(_ mode: DiffMode) -> [DiffTableRow] {
        mode == .split ? splitRows : rows(mode).map(DiffTableRow.single)
    }

    /// The diff whose line ids the rows of `mode` carry: the one a patch is built from.
    func file(_ mode: DiffMode) -> FileDiff? { mode == .full ? full ?? diff : diff }

    /// Nil when git printed no diff for this side. Tokens come from scanning the full-context diff from the file's
    /// first line, one scan state per side, so a hunk that starts inside a block comment is colored right.
    nonisolated init?(side: DiffSide, diff: FileDiff?, full: FileDiff?, language: Language?) {
        guard let diff else { return nil }
        self.side = side
        self.diff = diff
        self.full = full
        let tokens = DiffRowBuilder.tokens(full ?? diff, language: language)
        rows = DiffRowBuilder.rows(diff, tokens: tokens)
        fullRows = full.map { DiffRowBuilder.rows($0, tokens: tokens) } ?? rows
        splitRows = DiffRowBuilder.split(rows)
        additions = diff.additions
        deletions = diff.deletions
    }

    /// An untracked file's text as added lines, numbered from 1.
    nonisolated init(untracked data: Data, language: Language?) {
        side = .untracked
        diff = nil
        full = nil
        rows = Self.lines(of: data, language: language) { index, text, tokens in
            DiffRow(kind: .added, id: nil, oldLine: nil, newLine: index + 1, text: text, tokens: tokens)
        }
        fullRows = rows
        splitRows = rows.map(DiffTableRow.single)
        additions = rows.count
        deletions = 0
    }

    /// An unchanged file's text as context lines, numbered from 1 on both sides.
    nonisolated init(unchanged data: Data, language: Language?) {
        side = .file
        diff = nil
        full = nil
        rows = Self.lines(of: data, language: language) { index, text, tokens in
            DiffRow(kind: .context, id: nil, oldLine: index + 1, newLine: index + 1, text: text, tokens: tokens)
        }
        fullRows = rows
        splitRows = rows.map(DiffTableRow.single)
        additions = 0
        deletions = 0
    }

    /// `data`'s lines (the empty one after a final line break dropped) with their syntax tokens, made into rows.
    private nonisolated static func lines(
        of data: Data, language: Language?, row: (Int, String, [SyntaxToken]) -> DiffRow
    ) -> [DiffRow] {
        var state = ScanState()
        var lines = data.split(separator: UInt8(ascii: "\n"), omittingEmptySubsequences: false)
        if lines.last?.isEmpty == true { lines.removeLast() }
        return lines.enumerated().map { index, bytes in
            let text = DiffRowBuilder.display(String(decoding: bytes, as: UTF8.self))
            return row(index, text, SyntaxScanner.scan(line: text, state: &state, language: language))
        }
    }
}

/// Builds the rows of a diff, off the main actor.
enum DiffRowBuilder {
    /// Each side's tokens by line number.
    struct SideTokens: Sendable {
        var old: [Int: [SyntaxToken]] = [:]
        var new: [Int: [SyntaxToken]] = [:]
    }

    /// Scans `source`'s lines in order, the old side's lines (context and removed) with one state and the new side's
    /// (context and added) with another. With the full-context diff that is every line of both files.
    nonisolated static func tokens(_ source: FileDiff, language: Language?) -> SideTokens {
        guard let language else { return SideTokens() }
        var tokens = SideTokens()
        var oldState = ScanState()
        var newState = ScanState()
        for hunk in source.hunks {
            for line in hunk.lines {
                let text = display(line.text)
                if line.kind != .added, let number = line.oldLine {
                    tokens.old[number] = SyntaxScanner.scan(line: text, state: &oldState, language: language)
                }
                if line.kind != .removed, let number = line.newLine {
                    tokens.new[number] = SyntaxScanner.scan(line: text, state: &newState, language: language)
                }
            }
        }
        return tokens
    }

    /// A header row per hunk, then its lines. A combined diff's lines get no id: PatchBuilder refuses them.
    nonisolated static func rows(_ file: FileDiff, tokens: SideTokens) -> [DiffRow] {
        var rows: [DiffRow] = []
        rows.reserveCapacity(file.hunks.reduce(file.hunks.count) { $0 + $1.lines.count })
        for (hunkIndex, hunk) in file.hunks.enumerated() {
            let header = "@@ -\(hunk.oldStart),\(hunk.oldCount) +\(hunk.newStart),\(hunk.newCount) @@"
            rows.append(DiffRow(
                kind: .hunk(hunkIndex), id: nil, oldLine: nil, newLine: nil,
                text: hunk.section.isEmpty ? header : header + " " + hunk.section, tokens: []))
            let first = rows.count
            for (lineIndex, line) in hunk.lines.enumerated() {
                let kind: DiffRow.Kind = switch line.kind {
                case .context: .context
                case .added: .added
                case .removed: .removed
                }
                let lineTokens = line.kind == .removed
                    ? line.oldLine.flatMap { tokens.old[$0] } : line.newLine.flatMap { tokens.new[$0] }
                rows.append(DiffRow(
                    kind: kind, id: file.isCombined ? nil : DiffLineID(hunk: hunkIndex, line: lineIndex),
                    oldLine: line.oldLine, newLine: line.newLine, text: display(line.text), tokens: lineTokens ?? []))
            }
            markChanges(&rows, from: first)
        }
        return rows
    }

    /// `rows` side by side: a context line on both sides, each block of removed lines next to the block of added lines
    /// right after it (line by line, the shorter block padded with empty cells), a hunk header across both.
    nonisolated static func split(_ rows: [DiffRow]) -> [DiffTableRow] {
        var result: [DiffTableRow] = []
        result.reserveCapacity(rows.count)
        var index = 0
        while index < rows.count {
            let row = rows[index]
            switch row.kind {
            case .hunk:
                result.append(.single(row))
                index += 1
            case .context:
                result.append(.pair(old: row, new: row))
                index += 1
            case .removed, .added:
                let removedStart = index
                while index < rows.count, rows[index].kind == .removed { index += 1 }
                let addedStart = index
                while index < rows.count, rows[index].kind == .added { index += 1 }
                let removed = rows[removedStart..<addedStart]
                let added = rows[addedStart..<index]
                for offset in 0..<max(removed.count, added.count) {
                    result.append(.pair(old: offset < removed.count ? removed[removedStart + offset] : nil,
                                        new: offset < added.count ? added[addedStart + offset] : nil))
                }
            }
        }
        return result
    }

    /// The text to show: without the CR of a CRLF line.
    nonisolated static func display(_ text: String) -> String {
        text.hasSuffix("\r") ? String(text.dropLast()) : text
    }

    /// Pairs each block of removed lines with the block of added lines right after it when both have as many lines,
    /// and marks what changed in each pair (between the common start and the common end).
    private nonisolated static func markChanges(_ rows: inout [DiffRow], from start: Int) {
        var index = start
        while index < rows.count {
            guard rows[index].kind == .removed else {
                index += 1
                continue
            }
            var removedEnd = index
            while removedEnd < rows.count, rows[removedEnd].kind == .removed { removedEnd += 1 }
            var addedEnd = removedEnd
            while addedEnd < rows.count, rows[addedEnd].kind == .added { addedEnd += 1 }
            if removedEnd - index == addedEnd - removedEnd {
                for offset in 0..<(removedEnd - index) {
                    let (old, new) = changedRanges(rows[index + offset].text, rows[removedEnd + offset].text)
                    rows[index + offset].emphasis = old
                    rows[removedEnd + offset].emphasis = new
                }
            }
            index = addedEnd
        }
    }

    /// The parts of `old` and `new` between their common prefix and suffix; nil when nothing is common (the whole line
    /// changed: the band says it already) or when a line is too long to be worth it.
    private nonisolated static func changedRanges(_ old: String, _ new: String) -> (NSRange?, NSRange?) {
        let a = Array(old.utf16)
        let b = Array(new.utf16)
        guard a.count < 2000, b.count < 2000 else { return (nil, nil) }
        let shorter = min(a.count, b.count)
        var prefix = 0
        while prefix < shorter, a[prefix] == b[prefix] { prefix += 1 }
        var suffix = 0
        while suffix < shorter - prefix, a[a.count - 1 - suffix] == b[b.count - 1 - suffix] { suffix += 1 }
        guard prefix + suffix > 0 else { return (nil, nil) }
        let oldLength = a.count - prefix - suffix
        let newLength = b.count - prefix - suffix
        return (oldLength > 0 ? NSRange(location: prefix, length: oldLength) : nil,
                newLength > 0 ? NSRange(location: prefix, length: newLength) : nil)
    }
}

// MARK: - Table

/// One diff section's table. `loadID`, `mode`, `wraps` and the code font size say which rows it shows and how: a new
/// load (after a stage), another mode, a wrap or a font size change reloads them; any other update only refreshes the
/// hunk buttons. `onApply` gets the action, the lines (the selected changed lines of a hunk, or the whole hunk) and the
/// diff they belong to.
struct DiffLineTable: NSViewRepresentable {
    let section: DiffSection
    let mode: DiffMode
    let loadID: Int
    /// A commit's diff in the file history: its hunks (or selected lines) can be reverted in the working tree.
    var reverts = false
    /// Read with whitespace ignored: its hunks no longer match the files, so nothing stages, discards or reverts them.
    var readOnly = false
    /// Long lines wrap to the card's width instead of scrolling sideways.
    var wraps = false
    /// The last Previous / Next Change press. The table with the keyboard focus follows it, or the first table of the
    /// file (`isFirst`) when none has it.
    var jump: DiffJump?
    var isFirst = true
    var onApply: @MainActor (PatchBuilder.Action, Set<DiffLineID>, FileDiff) -> Void = { _, _, _ in }
    var onClose: @MainActor () -> Void = {}
    /// The code font size: a new one reloads the rows at it.
    @AppStorage(PrefKey.codeFontSize.rawValue, store: Preferences.defaults) private(set) var fontSize = 12.0

    func makeCoordinator() -> DiffTableController { DiffTableController() }

    func makeNSView(context: Context) -> NSScrollView {
        let table = DiffTableView()
        table.style = .plain
        table.backgroundColor = .clear
        table.gridStyleMask = []
        table.intercellSpacing = .zero
        table.usesAutomaticRowHeights = false
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
        // Unwrapped, a long line scrolls sideways (wrapped or split, the table is the card's width).
        scroll.hasHorizontalScroller = true
        scroll.autohidesScrollers = true

        context.coordinator.attach(table)
        return scroll
    }

    func updateNSView(_ scroll: NSScrollView, context: Context) {
        context.coordinator.update(self)
    }
}

/// A Previous / Next Change press; `serial` tells a new press from a redraw.
struct DiffJump: Equatable {
    enum Direction { case previous, next }

    let direction: Direction
    let serial: Int
}

/// Fonts and column positions of a table's rows. The gutters fit the largest line number; the content width fits the
/// longest line, so an unwrapped table scrolls sideways. A file's own lines (untracked, or unchanged) have one number
/// each, so they get one gutter; so does each half of a split row.
struct DiffLayout {
    /// The code font at one size (`PrefKey.codeFontSize`) and the sizes that follow from it, made once per size.
    @MainActor
    final class Metrics {
        let size: CGFloat
        let font: NSFont
        let numberFont: NSFont
        let charWidth: CGFloat
        /// One line's row: 18 at 12 pt.
        let lineHeight: CGFloat
        let hunkHeight: CGFloat
        /// A wrapped line's height: a row of `n` lines is `n * wrapLineHeight + wrapPadding` high (one line:
        /// `lineHeight`).
        let wrapLineHeight: CGFloat
        let wrapPadding: CGFloat
        /// The `+`/`−` gutter: 16 at 12 pt.
        let signWidth: CGFloat

        private init(size: CGFloat) {
            self.size = size
            font = NSFont.monospacedSystemFont(ofSize: size, weight: .regular)
            numberFont = NSFont.monospacedDigitSystemFont(ofSize: size - 1, weight: .regular)
            charWidth = ("0" as NSString).size(withAttributes: [.font: font]).width
            lineHeight = (size * 1.5).rounded()
            // 36 at 12 pt: room for the hunk buttons.
            hunkHeight = max(36, lineHeight + 18)
            wrapLineHeight = (size * 1.25).rounded()
            wrapPadding = lineHeight - wrapLineHeight
            signWidth = (16 * size / 12).rounded()
        }

        private static var cache: [CGFloat: Metrics] = [:]

        /// The metrics at `size` points (kept between 8 and 32).
        static func of(_ size: CGFloat) -> Metrics {
            let size = min(max(size, 8), 32)
            if let metrics = cache[size] { return metrics }
            let metrics = Metrics(size: size)
            cache[size] = metrics
            return metrics
        }
    }

    /// The code font size the views show: the preference until a view sets the one it reads (`use`).
    @MainActor private(set) static var metrics: Metrics = {
        let stored = Preferences.defaults.double(forKey: PrefKey.codeFontSize.rawValue)
        return Metrics.of(stored > 0 ? stored : 12)
    }()

    /// The code font size every code view draws at from now on (a view calls it with the preference it reads, before
    /// it reloads for a new size).
    @MainActor static func use(_ size: CGFloat) {
        if metrics.size != size { metrics = Metrics.of(size) }
    }

    @MainActor static var font: NSFont { metrics.font }
    @MainActor static var numberFont: NSFont { metrics.numberFont }
    @MainActor static var charWidth: CGFloat { metrics.charWidth }
    @MainActor static var lineHeight: CGFloat { metrics.lineHeight }
    @MainActor static var hunkHeight: CGFloat { metrics.hunkHeight }
    @MainActor static var wrapLineHeight: CGFloat { metrics.wrapLineHeight }
    @MainActor static var wrapPadding: CGFloat { metrics.wrapPadding }
    @MainActor static var signWidth: CGFloat { metrics.signWidth }
    /// Spaces per tab.
    static let tabWidth = 4
    /// Room kept after the text at the trailing edge.
    static let trailingPadding: CGFloat = 8

    let numberWidth: CGFloat
    let contentWidth: CGFloat
    let oneGutter: Bool

    var newNumberX: CGFloat { oneGutter ? 0 : numberWidth }
    var signX: CGFloat { newNumberX + numberWidth }
    @MainActor var textX: CGFloat { signX + Self.signWidth }
    /// A split half's text, after its one number and its sign.
    @MainActor var splitTextX: CGFloat { numberWidth + Self.signWidth }

    @MainActor init(rows: [DiffRow], oneGutter: Bool) {
        var largest = 0
        var longest = 0
        for row in rows where row.isLine {
            largest = max(largest, row.oldLine ?? 0, row.newLine ?? 0)
            let tabs = row.text.utf16.count { $0 == 0x09 }
            longest = max(longest, row.text.utf16.count + tabs * (Self.tabWidth - 1))
        }
        let digits = max(3, String(largest).count)
        numberWidth = CGFloat(digits) * Self.charWidth + 14
        self.oneGutter = oneGutter
        contentWidth = (oneGutter ? 1 : 2) * numberWidth + Self.signWidth + CGFloat(longest) * Self.charWidth + 24
    }

    init() {
        numberWidth = 40
        contentWidth = 0
        oneGutter = false
    }

    /// The width a row's text wraps at in a row `rowWidth` wide: whole columns of the monospaced font (a little over,
    /// so the last column always fits), at least one.
    @MainActor func wrapWidth(rowWidth: CGFloat, split: Bool) -> CGFloat {
        let room = split ? rowWidth / 2 - splitTextX : rowWidth - textX
        let columns = max(1, Int((room - Self.trailingPadding) / Self.charWidth))
        return CGFloat(columns) * Self.charWidth + 0.5
    }

    /// How many lines `text` takes wrapped at `width` (`wrapWidth`). ASCII is counted by columns (tabs to the next
    /// stop), which is how the monospaced font lays it out; other text is measured.
    @MainActor static func wrappedLines(_ text: String, width: CGFloat) -> Int {
        guard !text.isEmpty else { return 1 }
        if text.utf8.allSatisfy({ $0 < 0x80 }) {
            let columns = max(1, Int(width / charWidth))
            var lines = 1
            var column = 0
            for unit in text.utf8 {
                var advance = unit == 0x09 ? tabWidth - column % tabWidth : 1
                if column + advance > columns, column > 0 {
                    lines += 1
                    column = 0
                    advance = unit == 0x09 ? tabWidth : 1
                }
                column += advance
            }
            return lines
        }
        let height = NSAttributedString(string: text, attributes: DiffLineDrawing.wrappedText)
            .boundingRect(with: NSSize(width: width, height: .greatestFiniteMagnitude), options: [.usesLineFragmentOrigin])
            .height
        return max(1, Int((height / wrapLineHeight).rounded(.up)))
    }

    /// A row's height with its text wrapped at `width`.
    @MainActor static func wrappedHeight(_ texts: [String], width: CGFloat) -> CGFloat {
        let lines = texts.map { wrappedLines($0, width: width) }.max() ?? 1
        return max(lineHeight, CGFloat(lines) * wrapLineHeight + wrapPadding)
    }
}

/// The diff table: its one column is as wide as the longest line or the card, whichever is wider (as wide as the card
/// when the lines wrap or split). Esc asks to go back, ⌘C copies the selected lines, a right-click opens the
/// selection's menu.
final class DiffTableView: NSTableView {
    var contentWidth: CGFloat = 0 {
        didSet { if contentWidth != oldValue { tile() } }
    }
    weak var controller: DiffTableController?
    /// Takes the keyboard once, when it first shows, so ⌘C and Esc work without a click.
    private var tookFocus = false

    override func tile() {
        super.tile()
        guard let clip = enclosingScrollView?.contentView, let column = tableColumns.first else { return }
        let width = max(contentWidth, clip.bounds.width)
        if abs(column.width - width) > 0.5 { column.width = width }
        controller?.widthChanged()
    }

    /// The clip view whose width the column follows (`tile`), observed while the table is in it.
    private weak var observedClip: NSClipView?

    override func viewDidMoveToSuperview() {
        super.viewDidMoveToSuperview()
        if let observedClip {
            NotificationCenter.default.removeObserver(self, name: NSView.frameDidChangeNotification, object: observedClip)
        }
        observedClip = enclosingScrollView?.contentView
        guard let clip = observedClip else { return }
        // A card wider or narrower: the column follows (when the lines wrap or split, it is the card's width).
        clip.postsFrameChangedNotifications = true
        NotificationCenter.default.addObserver(self, selector: #selector(clipResized), name: NSView.frameDidChangeNotification,
                                               object: clip)
    }

    @objc private func clipResized() {
        tile()
    }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        guard let window, !tookFocus else { return }
        tookFocus = true
        // The other tables of the same diff do not steal it.
        if !(window.firstResponder is DiffTableView) { window.makeFirstResponder(self) }
    }

    override func keyDown(with event: NSEvent) {
        // Escape: back to the graph.
        if event.keyCode == 53 {
            controller?.close()
        } else {
            super.keyDown(with: event)
        }
    }

    @objc func copy(_ sender: Any?) {
        controller?.copySelection()
    }

    override func menu(for event: NSEvent) -> NSMenu? {
        controller?.menu(at: row(at: convert(event.locationInWindow, from: nil)))
    }
}

/// The table's data source and delegate: it keeps the rows it shows and reloads only for a new load, mode or wrap.
@MainActor
final class DiffTableController: NSObject, NSTableViewDataSource, NSTableViewDelegate {
    private weak var table: DiffTableView?
    private var view: DiffLineTable?
    private var rows: [DiffTableRow] = []
    private var layout = DiffLayout()
    /// Wrapped rows' heights, for `heightsWidth` (the column's width they were measured at).
    private var heights: [CGFloat] = []
    private var heightsWidth: CGFloat = -1
    /// The last jump this table saw (followed or not), so a redraw does not repeat it.
    private var jumpSerial: Int?

    private struct Shown: Equatable {
        let loadID: Int
        let mode: DiffMode
        let side: DiffSide
        let wraps: Bool
        let fontSize: Double
    }

    private var shown: Shown?

    private static let lineID = NSUserInterfaceItemIdentifier("diffLine")
    private static let splitID = NSUserInterfaceItemIdentifier("diffSplit")
    private static let hunkID = NSUserInterfaceItemIdentifier("diffHunk")
    private static let rowID = NSUserInterfaceItemIdentifier("diffRow")

    func attach(_ table: DiffTableView) {
        self.table = table
        table.controller = self
        table.dataSource = self
        table.delegate = self
    }

    func update(_ view: DiffLineTable) {
        self.view = view
        guard let table else { return }
        let key = Shown(loadID: view.loadID, mode: view.mode, side: view.section.side, wraps: view.wraps,
                        fontSize: view.fontSize)
        DiffLayout.use(view.fontSize)
        if key != shown {
            let modeChanged = shown.map { $0.mode != key.mode } ?? false
            // A table that just appeared takes the press before it as seen.
            if shown == nil { jumpSerial = view.jump?.serial }
            shown = key
            rows = view.section.tableRows(view.mode)
            layout = DiffLayout(rows: view.section.rows(view.mode),
                                oneGutter: [.untracked, .file].contains(view.section.side))
            heightsWidth = -1
            // A reload after a stage keeps the scroll offset; the selection goes (its lines may be gone).
            // `reloadData` keeps the selected row indexes, which would now point at other lines, so clear them.
            table.reloadData()
            table.deselectAll(nil)
            table.contentWidth = view.wraps || view.mode == .split ? 0 : layout.contentWidth
            table.tile()
            if modeChanged { scrollToFirstChange(table) }
            #if DEBUG
            runLaunchStage()
            #endif
        } else {
            refreshHunkButtons()
        }
        if let jump = view.jump, jump.serial != jumpSerial {
            jumpSerial = jump.serial
            if isJumpTarget(table, view) { self.jump(jump.direction, in: table) }
        }
    }

    /// In Full file mode the first change is the interesting part: it goes near the top.
    private func scrollToFirstChange(_ table: NSTableView) {
        scroll(table, toRow: rows.firstIndex(where: \.isChange) ?? 0)
    }

    /// Scrolls so `row` sits three lines under the top.
    private func scroll(_ table: NSTableView, toRow row: Int) {
        guard let clip = table.enclosingScrollView?.contentView else { return }
        let y = row < rows.count ? max(0, table.rect(ofRow: row).minY - 3 * DiffLayout.lineHeight) : 0
        clip.scroll(to: clip.constrainBoundsRect(NSRect(origin: NSPoint(x: clip.bounds.minX, y: y),
                                                        size: clip.bounds.size)).origin)
        table.enclosingScrollView?.reflectScrolledClipView(clip)
    }

    /// The table with the keyboard focus, else the file's first table.
    private func isJumpTarget(_ table: NSTableView, _ view: DiffLineTable) -> Bool {
        guard let responder = table.window?.firstResponder as? DiffTableView else { return view.isFirst }
        return responder === table
    }

    /// Scrolls to the start of the previous or next block of changed rows, from where a jump leaves its change (three
    /// lines under the top). A beep when there is none that way.
    private func jump(_ direction: DiffJump.Direction, in table: NSTableView) {
        guard let clip = table.enclosingScrollView?.contentView else { return }
        let anchor = clip.bounds.minY + 3 * DiffLayout.lineHeight
        let starts = rows.indices.filter { index in
            rows[index].isChange && (index == 0 || !rows[index - 1].isChange)
        }
        let target = switch direction {
        case .next: starts.first { table.rect(ofRow: $0).minY > anchor + 1 }
        case .previous: starts.last { table.rect(ofRow: $0).minY < anchor - 1 }
        }
        guard let target else { return NSSound.beep() }
        scroll(table, toRow: target)
    }

    func close() {
        view?.onClose()
    }

    // MARK: Data

    func numberOfRows(in tableView: NSTableView) -> Int { rows.count }

    func tableView(_ tableView: NSTableView, heightOfRow row: Int) -> CGFloat {
        guard rows.indices.contains(row) else { return DiffLayout.lineHeight }
        guard rows[row].isLine else { return DiffLayout.hunkHeight }
        guard view?.wraps == true else { return DiffLayout.lineHeight }
        measureHeights()
        return heights.indices.contains(row) ? heights[row] : DiffLayout.lineHeight
    }

    /// The column's width, which wrapped rows are measured at.
    private var rowWidth: CGFloat {
        table?.tableColumns.first?.width ?? 0
    }

    /// Measures every wrapped row at the column's width, unless that was done already.
    private func measureHeights() {
        let width = rowWidth
        guard width != heightsWidth || heights.count != rows.count else { return }
        heightsWidth = width
        let split = view?.mode == .split
        let wrapWidth = layout.wrapWidth(rowWidth: width, split: split)
        heights = rows.map { row in
            switch row {
            case .single(let line):
                line.isLine ? DiffLayout.wrappedHeight([line.text], width: wrapWidth) : DiffLayout.hunkHeight
            case .pair(let old, let new):
                DiffLayout.wrappedHeight([old?.text, new?.text].compactMap { $0 }, width: wrapWidth)
            }
        }
    }

    /// The column got wider or narrower: wrapped rows are measured again (after this layout pass).
    func widthChanged() {
        guard view?.wraps == true, abs(rowWidth - heightsWidth) > 0.5 else { return }
        DispatchQueue.main.async { [weak self] in
            guard let self, let table, view?.wraps == true, abs(rowWidth - heightsWidth) > 0.5 else { return }
            measureHeights()
            table.noteHeightOfRows(withIndexesChanged: IndexSet(integersIn: 0..<rows.count))
        }
    }

    func tableView(_ tableView: NSTableView, rowViewForRow row: Int) -> NSTableRowView? {
        tableView.makeView(withIdentifier: Self.rowID, owner: nil) as? DiffRowView ?? {
            let view = DiffRowView()
            view.identifier = Self.rowID
            return view
        }()
    }

    func tableView(_ tableView: NSTableView, viewFor tableColumn: NSTableColumn?, row: Int) -> NSView? {
        guard rows.indices.contains(row) else { return nil }
        switch rows[row] {
        case .single(let data):
            if case .hunk(let hunk) = data.kind {
                let cell = tableView.makeView(withIdentifier: Self.hunkID, owner: nil) as? DiffHunkCellView ?? {
                    let cell = DiffHunkCellView()
                    cell.identifier = Self.hunkID
                    return cell
                }()
                cell.configure(text: data.text, buttons: buttons(forHunk: hunk)) { [weak self] action in
                    self?.apply(action, hunk: hunk)
                }
                return cell
            }
            let cell = tableView.makeView(withIdentifier: Self.lineID, owner: nil) as? DiffLineCellView ?? {
                let cell = DiffLineCellView()
                cell.identifier = Self.lineID
                return cell
            }()
            cell.row = data
            cell.layout = layout
            cell.wraps = view?.wraps == true
            cell.needsDisplay = true
            return cell
        case .pair(let old, let new):
            let cell = tableView.makeView(withIdentifier: Self.splitID, owner: nil) as? DiffSplitCellView ?? {
                let cell = DiffSplitCellView()
                cell.identifier = Self.splitID
                return cell
            }()
            cell.set(old: old, new: new)
            cell.layout = layout
            cell.wraps = view?.wraps == true
            cell.needsDisplay = true
            return cell
        }
    }

    /// Hunk headers are not lines: a click or a drag never selects them.
    func tableView(_ tableView: NSTableView, selectionIndexesForProposedSelection proposed: IndexSet) -> IndexSet {
        proposed.filteredIndexSet { rows.indices.contains($0) && rows[$0].isLine }
    }

    func tableViewSelectionDidChange(_ notification: Notification) {
        refreshHunkButtons()
    }

    // MARK: Actions

    /// The changed lines selected in `hunk` (a split row selects its old and its new line).
    private func selectedLines(inHunk hunk: Int) -> Set<DiffLineID> {
        Set(selectedChangedRows().compactMap { $0.id?.hunk == hunk ? $0.id : nil })
    }

    /// The changed lines of the selected rows.
    private func selectedChangedRows() -> [DiffRow] {
        guard let table else { return [] }
        return table.selectedRowIndexes.flatMap { index in
            rows.indices.contains(index) ? rows[index].lines.filter(\.isChange) : []
        }
    }

    /// The header's buttons: "Stage Hunk", or "Stage 2 Lines" while lines of that hunk are selected. None for a
    /// read-only diff (a commit outside the file history, a merge's combined diff, an untracked file, whitespace
    /// ignored).
    private func buttons(forHunk hunk: Int) -> [(PatchBuilder.Action, String)] {
        guard let view, let file = view.section.file(view.mode), !file.isCombined else { return [] }
        let count = selectedLines(inHunk: hunk).count
        let what = count == 0 ? "Hunk" : count == 1 ? "1 Line" : "\(count) Lines"
        return actions(view).map { action in
            let verb = switch action {
            case .stage: "Stage"
            case .unstage: "Unstage"
            case .discard: "Discard"
            case .revert: "Revert"
            }
            return (action, "\(verb) \(what)")
        }
    }

    /// The side's actions, and Revert for a commit's diff in the file history. Not in Full file: its one hunk has
    /// the whole file as context, which no longer applies once the file changed after the commit. None while
    /// whitespace is ignored.
    private func actions(_ view: DiffLineTable) -> [PatchBuilder.Action] {
        guard !view.readOnly else { return [] }
        guard view.reverts, view.section.side == .commit else { return view.section.side.actions }
        return view.mode == .full ? [] : [.revert]
    }

    private func refreshHunkButtons() {
        guard let table else { return }
        let visible = table.rows(in: table.visibleRect)
        for index in visible.location..<NSMaxRange(visible) where rows.indices.contains(index) {
            guard let hunk = rows[index].hunk, case .single(let header) = rows[index],
                  let cell = table.view(atColumn: 0, row: index, makeIfNecessary: false) as? DiffHunkCellView
            else { continue }
            cell.configure(text: header.text, buttons: buttons(forHunk: hunk)) { [weak self] action in
                self?.apply(action, hunk: hunk)
            }
        }
    }

    /// A hunk button: the hunk's selected changed lines, or the whole hunk when none is selected.
    private func apply(_ action: PatchBuilder.Action, hunk: Int) {
        guard let view, let file = view.section.file(view.mode), file.hunks.indices.contains(hunk) else { return }
        let selected = selectedLines(inHunk: hunk)
        view.onApply(action, selected.isEmpty ? Set(file.changedLineIDs(inHunk: hunk)) : selected, file)
    }

    /// The selected lines, whole, one per line (no `+`/`−`, no line numbers; a split row's old line, then its new one).
    func copySelection() {
        guard let table else { return }
        let lines = table.selectedRowIndexes.flatMap { rows.indices.contains($0) ? rows[$0].lines.map(\.text) : [] }
        guard !lines.isEmpty else { return }
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(lines.joined(separator: "\n") + "\n", forType: .string)
    }

    /// A right-click on a line: it joins the selection (or replaces it when it was not selected), then Copy and the
    /// side's actions on the selected lines.
    func menu(at row: Int) -> NSMenu? {
        guard let table, let view, rows.indices.contains(row), rows[row].isLine else { return nil }
        if !table.selectedRowIndexes.contains(row) {
            table.selectRowIndexes(IndexSet(integer: row), byExtendingSelection: false)
        }
        var entries: [MenuEntry] = [.action("Copy") { [weak self] in self?.copySelection() }]
        let lines = Set(selectedChangedRows().compactMap(\.id))
        if let file = view.section.file(view.mode), !file.isCombined, !lines.isEmpty, !actions(view).isEmpty {
            let what = lines.count == 1 ? "1 Line" : "\(lines.count) Lines"
            entries.append(.separator)
            for action in actions(view) {
                switch action {
                case .stage: entries.append(.action("Stage \(what)") { view.onApply(.stage, lines, file) })
                case .unstage: entries.append(.action("Unstage \(what)") { view.onApply(.unstage, lines, file) })
                case .discard:
                    entries.append(.action("Discard \(what)…", destructive: true) { view.onApply(.discard, lines, file) })
                case .revert:
                    entries.append(.action("Revert \(what)…") { view.onApply(.revert, lines, file) })
                }
            }
        }
        return MenuBuilder.menu(entries)
    }

    #if DEBUG
    /// Whether `-HistqStageLines` already ran in this launch.
    private static var launchStageDone = false

    /// DEBUG `-HistqStageLines <n>,<m>`: once, in the first table that can stage, selects the changed lines with those
    /// line numbers (new numbers for added lines, old for removed) and presses their hunk's Stage button, the path a
    /// user's selection and click take.
    private func runLaunchStage() {
        guard !Self.launchStageDone, let table, let view, actions(view).contains(.stage),
              let spec = AppState.launchFlag("-HistqStageLines")
        else { return }
        Self.launchStageDone = true
        let wanted = Set(spec.split(separator: ",").compactMap { Int($0.trimmingCharacters(in: .whitespaces)) })
        let indexes = IndexSet(rows.indices.filter { index in
            rows[index].lines.contains { line in
                switch line.kind {
                case .added: wanted.contains(line.newLine ?? -1)
                case .removed: wanted.contains(line.oldLine ?? -1)
                case .context, .hunk: false
                }
            }
        })
        guard let first = indexes.first, let hunk = rows[first].lines.first(where: \.isChange)?.id?.hunk else { return }
        table.selectRowIndexes(indexes, byExtendingSelection: false)
        apply(.stage, hunk: hunk)
    }
    #endif
}

// MARK: - Rows

/// A selected line: the graph's neutral fill and edge, under the line's own band.
final class DiffRowView: NSTableRowView {
    override var interiorBackgroundStyle: NSView.BackgroundStyle { .normal }

    override func drawSelection(in dirtyRect: NSRect) {
        let rect = bounds.insetBy(dx: 2, dy: 0)
        Palette.graphSelection.setFill()
        NSBezierPath(roundedRect: rect, xRadius: 3, yRadius: 3).fill()
        Palette.graphSelectionBorder.setStroke()
        let edge = NSBezierPath(roundedRect: rect.insetBy(dx: 0.5, dy: 0.5), xRadius: 2.5, yRadius: 2.5)
        edge.lineWidth = 1
        edge.stroke()
    }
}

/// How a line draws, shared by the unified and the split cells: its band, its numbers, the sign, the changed part's
/// mark, then the text in syntax colors, on one line (clipped by the cell) or wrapped.
@MainActor
enum DiffLineDrawing {
    /// Where a line's parts go, from the left of the rect it draws in.
    struct Spots {
        /// Each number gutter's line number (nil: blank) and left edge; each is `numberWidth` wide.
        var numbers: [(Int?, CGFloat)]
        var numberWidth: CGFloat
        var signX: CGFloat
        var textX: CGFloat
        /// The width the text wraps at (`DiffLayout.wrapWidth`); nil for one line.
        var wrapWidth: CGFloat?
    }

    /// The attributes at one code font size.
    @MainActor
    private struct Style {
        let text: [NSAttributedString.Key: Any]
        let wrappedText: [NSAttributedString.Key: Any]
        let number: [NSAttributedString.Key: Any]
        let addedSign: [NSAttributedString.Key: Any]
        let removedSign: [NSAttributedString.Key: Any]

        init(_ metrics: DiffLayout.Metrics) {
            let paragraph = NSMutableParagraphStyle()
            paragraph.tabStops = []
            paragraph.defaultTabInterval = CGFloat(DiffLayout.tabWidth) * metrics.charWidth
            paragraph.lineBreakMode = .byClipping
            let wrappedParagraph = NSMutableParagraphStyle()
            wrappedParagraph.tabStops = []
            wrappedParagraph.defaultTabInterval = CGFloat(DiffLayout.tabWidth) * metrics.charWidth
            // By character, as `DiffLayout.wrappedLines` counts, with a fixed line height.
            wrappedParagraph.lineBreakMode = .byCharWrapping
            wrappedParagraph.minimumLineHeight = metrics.wrapLineHeight
            wrappedParagraph.maximumLineHeight = metrics.wrapLineHeight
            let numberParagraph = NSMutableParagraphStyle()
            numberParagraph.alignment = .right
            text = [.font: metrics.font, .foregroundColor: Palette.diffText, .paragraphStyle: paragraph]
            wrappedText = [.font: metrics.font, .foregroundColor: Palette.diffText, .paragraphStyle: wrappedParagraph]
            number = [.font: metrics.numberFont, .foregroundColor: Palette.diffLineNumber,
                      .paragraphStyle: numberParagraph]
            addedSign = [.font: metrics.font, .foregroundColor: Palette.diffAddedSign]
            removedSign = [.font: metrics.font, .foregroundColor: Palette.diffRemovedSign]
        }
    }

    private static var styles: [CGFloat: Style] = [:]

    /// The attributes at the current code font size, made once per size.
    private static var style: Style {
        let metrics = DiffLayout.metrics
        if let style = styles[metrics.size] { return style }
        let style = Style(metrics)
        styles[metrics.size] = style
        return style
    }

    /// The attributes of wrapped text (what `DiffLayout.wrappedLines` measures with).
    static var wrappedText: [NSAttributedString.Key: Any] { style.wrappedText }

    private static func color(_ kind: TokenKind) -> NSColor {
        switch kind {
        case .keyword: Palette.syntaxKeyword
        case .string: Palette.syntaxString
        case .number: Palette.syntaxNumber
        case .comment: Palette.syntaxComment
        case .type: Palette.syntaxType
        case .punctuation: Palette.syntaxPunctuation
        case .plain: Palette.diffText
        }
    }

    /// Draws `row` in `rect` (a flipped view's coordinates). The numbers and the sign sit on the first line.
    static func draw(_ row: DiffRow, in rect: NSRect, spots: Spots) {
        let style = style
        switch row.kind {
        case .added:
            Palette.diffAddedFill.setFill()
            rect.fill(using: .sourceOver)
        case .removed:
            Palette.diffRemovedFill.setFill()
            rect.fill(using: .sourceOver)
        case .context, .hunk:
            break
        }
        // One line's height: a wrapped row's numbers and sign stay on its first line.
        let lineHeight = spots.wrapWidth == nil ? rect.height : DiffLayout.lineHeight
        let numberY = rect.minY + (lineHeight - DiffLayout.numberFont.boundingRectForFont.height) / 2
        for (value, x) in spots.numbers {
            guard let value else { continue }
            NSString(string: "\(value)").draw(
                in: NSRect(x: rect.minX + x, y: numberY, width: spots.numberWidth - 8, height: lineHeight),
                withAttributes: style.number)
        }
        let textY = rect.minY + (lineHeight - (DiffLayout.font.ascender - DiffLayout.font.descender)) / 2
        switch row.kind {
        case .added:
            NSString(string: "+").draw(at: NSPoint(x: rect.minX + spots.signX + 4, y: textY), withAttributes: style.addedSign)
        case .removed:
            NSString(string: "−").draw(at: NSPoint(x: rect.minX + spots.signX + 4, y: textY), withAttributes: style.removedSign)
        case .context, .hunk:
            break
        }

        let wraps = spots.wrapWidth != nil
        let text = NSMutableAttributedString(string: row.text, attributes: wraps ? style.wrappedText : style.text)
        let length = text.length
        for token in row.tokens where NSMaxRange(token.range) <= length {
            text.addAttribute(.foregroundColor, value: color(token.kind), range: token.range)
        }
        let emphasisFill = row.kind == .added ? Palette.diffAddedEmphasis : Palette.diffRemovedEmphasis
        if let wrapWidth = spots.wrapWidth {
            // The mark may span lines: a background on the text itself.
            if let emphasis = row.emphasis, NSMaxRange(emphasis) <= length {
                text.addAttribute(.backgroundColor, value: emphasisFill, range: emphasis)
            }
            text.draw(with: NSRect(x: rect.minX + spots.textX, y: rect.minY + DiffLayout.wrapPadding / 2,
                                   width: wrapWidth, height: rect.height),
                      options: [.usesLineFragmentOrigin])
            return
        }
        if let emphasis = row.emphasis, NSMaxRange(emphasis) <= length {
            // Measured on the text itself, so tabs before the mark are counted as drawn.
            let start = text.attributedSubstring(from: NSRange(location: 0, length: emphasis.location)).size().width
            let width = text.attributedSubstring(from: emphasis).size().width
            emphasisFill.setFill()
            NSBezierPath(roundedRect: NSRect(x: rect.minX + spots.textX + start, y: rect.minY + 1, width: width,
                                             height: rect.height - 2),
                         xRadius: 2, yRadius: 2).fill()
        }
        text.draw(at: NSPoint(x: rect.minX + spots.textX, y: textY))
    }
}

/// A line: its band, the old and new numbers, the sign, the changed part's mark, then the text in syntax colors.
final class DiffLineCellView: NSView {
    var row: DiffRow? {
        didSet { setAccessibilityLabel(row?.text) }
    }
    var layout = DiffLayout()
    var wraps = false

    override var isFlipped: Bool { true }
    override var isOpaque: Bool { false }

    override init(frame: NSRect) {
        super.init(frame: frame)
        setAccessibilityElement(true)
        setAccessibilityRole(.staticText)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) is not used") }

    override func setFrameSize(_ newSize: NSSize) {
        // Wrapped text reflows with the width.
        if wraps, newSize.width != frame.width { needsDisplay = true }
        super.setFrameSize(newSize)
    }

    override func draw(_ dirtyRect: NSRect) {
        guard let row else { return }
        let numbers: [(Int?, CGFloat)] = layout.oneGutter
            ? [(row.newLine, layout.newNumberX)]
            : [(row.oldLine, 0), (row.newLine, layout.newNumberX)]
        DiffLineDrawing.draw(row, in: bounds, spots: DiffLineDrawing.Spots(
            numbers: numbers, numberWidth: layout.numberWidth, signX: layout.signX, textX: layout.textX,
            wrapWidth: wraps ? layout.wrapWidth(rowWidth: bounds.width, split: false) : nil))
    }
}

/// A split row: the old line on the left half (its old number), the new line on the right half (its new number), a
/// thin rule between them. A missing side stays empty; each half clips its own text.
final class DiffSplitCellView: NSView {
    private var old: DiffRow?
    private var new: DiffRow?
    var layout = DiffLayout()
    var wraps = false

    override var isFlipped: Bool { true }
    override var isOpaque: Bool { false }

    override init(frame: NSRect) {
        super.init(frame: frame)
        setAccessibilityElement(true)
        setAccessibilityRole(.staticText)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) is not used") }

    func set(old: DiffRow?, new: DiffRow?) {
        self.old = old
        self.new = new
        setAccessibilityLabel(old?.kind == .context ? old?.text
            : [old.map { "Removed: \($0.text)" }, new.map { "Added: \($0.text)" }].compactMap { $0 }
                .joined(separator: ", "))
    }

    override func setFrameSize(_ newSize: NSSize) {
        if newSize.width != frame.width { needsDisplay = true }
        super.setFrameSize(newSize)
    }

    override func draw(_ dirtyRect: NSRect) {
        let half = (bounds.width / 2).rounded(.down)
        let wrapWidth = wraps ? layout.wrapWidth(rowWidth: bounds.width, split: true) : nil
        for (row, rect, number) in [(old, NSRect(x: 0, y: 0, width: half, height: bounds.height), old?.oldLine),
                                    (new, NSRect(x: half, y: 0, width: bounds.width - half, height: bounds.height),
                                     new?.newLine)] {
            guard let row else { continue }
            NSGraphicsContext.saveGraphicsState()
            NSBezierPath(rect: rect).addClip()
            DiffLineDrawing.draw(row, in: rect, spots: DiffLineDrawing.Spots(
                numbers: [(number, 0)], numberWidth: layout.numberWidth, signX: layout.numberWidth,
                textX: layout.splitTextX, wrapWidth: wrapWidth))
            NSGraphicsContext.restoreGraphicsState()
        }
        NSColor.separatorColor.setFill()
        NSRect(x: half - 0.5, y: 0, width: 1, height: bounds.height).fill()
    }
}

/// A hunk's header: its `@@` range and section, then its buttons at the trailing edge.
final class DiffHunkCellView: NSView {
    private let label = NSTextField(labelWithString: "")
    private let stack = NSStackView()
    private var onAction: ((PatchBuilder.Action) -> Void)?
    private var actions: [PatchBuilder.Action] = []

    override var isFlipped: Bool { true }

    override init(frame: NSRect) {
        super.init(frame: frame)
        label.textColor = .secondaryLabelColor
        label.lineBreakMode = .byTruncatingTail
        label.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        stack.orientation = .horizontal
        stack.spacing = 6
        for view in [label, stack] {
            view.translatesAutoresizingMaskIntoConstraints = false
            addSubview(view)
        }
        NSLayoutConstraint.activate([
            label.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 10),
            label.centerYAnchor.constraint(equalTo: centerYAnchor),
            stack.leadingAnchor.constraint(greaterThanOrEqualTo: label.trailingAnchor, constant: 8),
            stack.centerYAnchor.constraint(equalTo: centerYAnchor),
        ])
        // The buttons stay in the card's visible width even when a long line widens the table.
        trailingConstraint = stack.trailingAnchor.constraint(equalTo: leadingAnchor, constant: 0)
        trailingConstraint?.isActive = true
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) is not used") }

    private var trailingConstraint: NSLayoutConstraint?

    override func layout() {
        let visible = enclosingScrollView?.contentView.bounds.width ?? bounds.width
        trailingConstraint?.constant = min(bounds.width, visible) - 8
        super.layout()
    }

    func configure(text: String, buttons: [(PatchBuilder.Action, String)],
                   onAction: @escaping (PatchBuilder.Action) -> Void)
    {
        label.stringValue = text
        label.font = DiffLayout.numberFont
        self.onAction = onAction
        actions = buttons.map(\.0)
        for view in stack.arrangedSubviews {
            stack.removeArrangedSubview(view)
            view.removeFromSuperview()
        }
        for (index, (action, title)) in buttons.enumerated() {
            // Stage is green, Discard a light red (user, 2026-11-17); Unstage keeps the plain bezel.
            let fill: NSColor? = switch action {
            case .stage: Palette.diffAddedSign.withAlphaComponent(0.5)
            case .discard: Palette.diffRemovedSign.withAlphaComponent(0.3)
            case .unstage, .revert: nil
            }
            let button = fill.map { TintedCapsuleButton(title: title, fill: $0) } ?? NSButton(title: title, target: nil, action: nil)
            button.target = self
            button.action = #selector(pressed(_:))
            if fill == nil {
                button.bezelStyle = .push
                // Every button of the app is a capsule (user, 2026-11-13); before macOS 26 AppKit has no shape to pick.
                if #available(macOS 26, *) { button.borderShape = .capsule }
                button.controlSize = .small
                button.font = .systemFont(ofSize: NSFont.systemFontSize(for: .small))
            }
            button.tag = index
            button.hasDestructiveAction = action == .discard
            stack.addArrangedSubview(button)
        }
        needsLayout = true
    }

    @objc private func pressed(_ sender: NSButton) {
        guard actions.indices.contains(sender.tag) else { return }
        onAction?(actions[sender.tag])
    }

    override func draw(_ dirtyRect: NSRect) {
        Palette.diffHunkFill.setFill()
        bounds.fill(using: .sourceOver)
    }
}

/// A hunk header's colored capsule button with a white title. A push button's `bezelColor` turns grey whenever the
/// window is not key, so the capsule is a layer fill that keeps its color; a hover brightens it, a press dims it.
final class TintedCapsuleButton: NSButton {
    private let fill: NSColor
    private var hovered = false

    init(title: String, fill: NSColor) {
        self.fill = fill
        super.init(frame: .zero)
        attributedTitle = NSAttributedString(string: title, attributes: [
            .font: NSFont.systemFont(ofSize: NSFont.systemFontSize(for: .small)),
            .foregroundColor: NSColor.white,
        ])
        isBordered = false
        wantsLayer = true
        layer?.backgroundColor = fill.cgColor
        addTrackingArea(NSTrackingArea(rect: .zero, options: [.mouseEnteredAndExited, .activeAlways, .inVisibleRect],
                                       owner: self))
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) is not used") }

    /// The small push button's size: its title plus 10 pt on each side, 22 pt tall.
    override var intrinsicContentSize: NSSize {
        NSSize(width: super.intrinsicContentSize.width + 20, height: 22)
    }

    override var isHighlighted: Bool {
        didSet { updateFill(animated: false) }
    }

    override func mouseEntered(with event: NSEvent) {
        hovered = true
        updateFill(animated: true)
    }

    override func mouseExited(with event: NSEvent) {
        hovered = false
        updateFill(animated: true)
    }

    private func updateFill(animated: Bool) {
        let alpha = fill.alphaComponent * (isHighlighted ? 0.6 : hovered ? 1.5 : 1)
        let color = fill.withAlphaComponent(min(alpha, 1)).cgColor
        NSAnimationContext.runAnimationGroup { context in
            context.duration = animated ? 0.12 : 0
            context.allowsImplicitAnimation = animated
            layer?.backgroundColor = color
        }
    }

    override func layout() {
        super.layout()
        layer?.cornerRadius = bounds.height / 2
    }
}
