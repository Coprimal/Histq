// The lines of one side of a file's diff: an NSTableView whose rows are one line high, or as high as their wrapped text
// (Wrap Lines). Each line row has the old and new line numbers, a `+`/`−` gutter, a green or red band, a stronger mark
// on the changed part of a replaced line, and syntax colors; in Split a row has the old line on the left and the new
// one on the right. Each hunk starts with a header row whose buttons stage, unstage, discard or revert the hunk, or only
// its selected lines (none while whitespace is ignored). A click selects a line; a drag in the text selects text (never
// the numbers or the signs; in Split, on one side). ⌘C copies the selected text, else the selected lines whole; Esc goes
// back to the graph.
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
    /// A review thread under the line before it (only in a table given `DiffLineTable.inlineThreads`).
    case thread(DiffInlineThread)
    /// The new comment's box under its (last) line (only with `DiffInlineThreads.newComments`).
    case composer(DiffInlineComposer)

    /// The hunk whose header this row is.
    var hunk: Int? {
        if case .single(let row) = self, case .hunk(let index) = row.kind { index } else { nil }
    }

    /// A line (or a split pair of lines): not a hunk header or a thread.
    var isLine: Bool {
        switch self {
        case .single(let row): row.isLine
        case .pair: true
        case .thread, .composer: false
        }
    }

    /// The lines the row shows (a context line once).
    var lines: [DiffRow] {
        switch self {
        case .single(let row): row.isLine ? [row] : []
        case .pair(let old, let new): old?.kind == .context ? [old].compactMap { $0 } : [old, new].compactMap { $0 }
        case .thread, .composer: []
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
    /// The tab's repo folder name, for the `focus` timing line.
    let repo: String
    /// A commit's diff (file history or graph): its hunks (or selected lines) can be reverted in the working tree.
    var reverts = false
    /// Read with whitespace ignored: its hunks no longer match the files, so nothing stages, discards or reverts them.
    var readOnly = false
    /// Long lines wrap to the card's width instead of scrolling sideways.
    var wraps = false
    /// The last Previous / Next Change press. The table with the keyboard focus follows it, or the first table of the
    /// file (`isFirst`) when none has it.
    var jump: DiffJump?
    var isFirst = true
    /// Gets the table once made (the session's `diffTable`, the keyboard's target when the tab shows).
    var onTable: @MainActor (NSView) -> Void = { _ in }
    /// A pull request's Files changed only: its review threads, each in a row under its line. nil everywhere else
    /// (the staging, commit and file diffs), which keeps their rows as they are.
    var inlineThreads: DiffInlineThreads?
    var onApply: @MainActor (PatchBuilder.Action, Set<DiffLineID>, FileDiff) -> Void = { _, _, _ in }
    var onClose: @MainActor () -> Void = {}
    /// The code font size: a new one reloads the rows at it.
    @AppStorage(PrefKey.codeFontSize.rawValue, store: Preferences.defaults) private(set) var fontSize = 12.0
    @Environment(\.tabIsShown) private var tabIsShown

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
        table.repo = repo
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
        scroll.isHidden = !tabIsShown

        context.coordinator.attach(table)
        onTable(table)
        return scroll
    }

    func updateNSView(_ scroll: NSScrollView, context: Context) {
        // The tab showing again moves the keyboard itself (`WindowModel.focusShownTab`).
        if scroll.isHidden == tabIsShown { scroll.isHidden = !tabIsShown }
        context.coordinator.update(self)
    }
}

/// A Previous / Next Change press; `serial` tells a new press from a redraw.
struct DiffJump: Equatable {
    enum Direction { case previous, next }

    let direction: Direction
    let serial: Int
}

/// A review thread drawn under a diff line: its comments as plain text (never HTML), the replies indented.
struct DiffInlineThread: Equatable, Sendable {
    struct Comment: Equatable, Sendable {
        let author: String
        /// Already formatted.
        let date: String
        let body: String
        let isReply: Bool
        /// A comment of the viewer's pending review: a "Pending" capsule after the author.
        var isPending = false
        /// Its suggested changes (`body` without their blocks), drawn under the text as −/+ lines.
        var suggestions: [Suggestion] = []
        /// The comment's id, which its Show toggle is kept by.
        var id = 0
        /// Hidden on the host: the note after the author ("hidden as outdated"), and its text only behind a Show
        /// toggle; nil for a comment shown as any other.
        var hiddenNote: String? = nil
    }

    /// A suggested change: the lines it replaces (empty when unknown) and its new lines.
    struct Suggestion: Equatable, Sendable {
        let old: [String]
        let new: [String]
    }

    let id: Int
    /// The line it sits under: a new-side line number (`newSide`), else an old-side one.
    let line: Int
    let newSide: Bool
    /// "Line 6" or "Lines 4–6".
    let title: String
    let isResolved: Bool
    let comments: [Comment]
}

/// What the Files changed tab of a pull request gives its table: the file's threads, which of them show collapsed
/// (their header only), and what a click on a header or on "Reply in Conversation" does.
struct DiffInlineThreads {
    /// The file's path, for the DEBUG probe.
    let path: String
    let threads: [DiffInlineThread]
    let collapsed: Set<Int>
    /// A header click: the thread's id and whether it is collapsed now (the table shows it at once).
    let onToggle: @MainActor (Int, Bool) -> Void
    let onReply: @MainActor () -> Void
    /// The reply button's title: "Reply in Conversation", or the host's tab name ("Reply in Overview").
    var replyTitle = "Reply in Conversation"
    /// Where the host takes new inline comments: the "+" on a hovered line and the open comment box. nil hides both.
    var newComments: DiffNewComments?
}

/// A diff line as its row shows it: what a new inline comment goes on.
struct DiffInlineLine: Equatable, Sendable {
    let kind: HostedInlinePosition.LineKind
    let oldLine: Int?
    let newLine: Int?

    /// A line row's line; nil for a hunk header.
    init?(_ row: DiffRow) {
        switch row.kind {
        case .added: kind = .added
        case .removed: kind = .removed
        case .context: kind = .context
        case .hunk: return nil
        }
        oldLine = row.oldLine
        newLine = row.newLine
    }

    init(kind: HostedInlinePosition.LineKind, oldLine: Int?, newLine: Int?) {
        self.kind = kind
        self.oldLine = oldLine
        self.newLine = newLine
    }

    /// The number shown for it: the old one of a removed line, else the new one.
    var number: Int? { kind == .removed ? oldLine : newLine }

    /// `R6` (new side) or `L3` (a removed line), for the DEBUG probe.
    var probe: String { (kind == .removed ? "L" : "R") + (number.map(String.init) ?? "?") }
}

/// The open new comment box of a file: under `end`, on the lines from `start` for a range; `message` says why the
/// last range asked for was refused.
struct DiffInlineComposer: Equatable, Sendable {
    var end: DiffInlineLine
    var start: DiffInlineLine?
    var message: String?

    /// "Comment on line 6", "Comment on lines 4–6"; a range from a removed line to a new one marks each side
    /// ("Comment on lines −3–+5").
    var title: String {
        guard let start else { return "Comment on line \(end.number.map(String.init) ?? "?")" }
        let mixed = (start.kind == .removed) != (end.kind == .removed)
        func label(_ line: DiffInlineLine) -> String {
            (mixed ? (line.kind == .removed ? "−" : "+") : "") + (line.number.map(String.init) ?? "?")
        }
        return "Comment on lines \(label(start))–\(label(end))"
    }
}

/// A pull request's Files changed where the host takes new inline comments: the open box of this file, whether a
/// shift-click makes a range, the host's range rule, and the box's text and buttons. The text lives with the owner
/// (read when the box shows, written as it is typed), so a reload of the rows keeps it.
struct DiffNewComments {
    let composer: DiffInlineComposer?
    let allowsRange: Bool
    /// Another action of the pull request runs: Comment waits.
    let isBusy: Bool
    /// Why the host refuses a range from the first line to the second (both shown, in order); nil when it takes it.
    let refusal: @MainActor (DiffInlineLine, DiffInlineLine) -> String?
    let draft: @MainActor () -> String
    /// A "+" click: the box opened (or moved, or made a range); the table shows it at once.
    let onOpen: @MainActor (DiffInlineComposer) -> Void
    let onDraft: @MainActor (String) -> Void
    let onCancel: @MainActor () -> Void
    let onPost: @MainActor (String) -> Void
    /// The main button's title: "Comment", or "Add review comment" where the host routes it into the pending review.
    var commentTitle = "Comment"
    /// A second button beside it that adds the text to the pending review ("Start a review", "Add review comment");
    /// nil shows none.
    var review: (title: String, onPost: @MainActor (String) -> Void)?
    /// The host's suggestion block holding the box's lines (their current text), which "Suggest a change" inserts;
    /// nil shows no button (a host without suggestions).
    var suggestion: (@MainActor ([String]) -> String)?
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
    /// The tab's repo folder name, for the `focus` timing line.
    var repo = ""
    /// A pull request's Files changed where the host takes new comments: the pointer is followed for the "+"
    /// (`DiffTableController.hoverComment`). Every other table never tracks it.
    var tracksCommentHover = false {
        didSet {
            guard tracksCommentHover != oldValue else { return }
            updateTrackingAreas()
            observeClipScroll()
        }
    }
    private var hoverArea: NSTrackingArea?

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        if let hoverArea { removeTrackingArea(hoverArea) }
        hoverArea = nil
        guard tracksCommentHover else { return }
        let area = NSTrackingArea(rect: .zero, options: [.mouseMoved, .mouseEnteredAndExited, .activeInKeyWindow,
                                                         .inVisibleRect], owner: self)
        addTrackingArea(area)
        hoverArea = area
    }

    override func mouseMoved(with event: NSEvent) {
        super.mouseMoved(with: event)
        if tracksCommentHover { controller?.hoverComment(at: convert(event.locationInWindow, from: nil)) }
    }

    override func mouseExited(with event: NSEvent) {
        super.mouseExited(with: event)
        if tracksCommentHover { controller?.hoverComment(at: nil) }
    }

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
        observeClipScroll()
        guard let clip = observedClip else { return }
        // A card wider or narrower: the column follows (when the lines wrap or split, it is the card's width).
        clip.postsFrameChangedNotifications = true
        NotificationCenter.default.addObserver(self, selector: #selector(clipResized), name: NSView.frameDidChangeNotification,
                                               object: clip)
    }

    @objc private func clipResized() {
        tile()
    }

    /// The clip view whose scrolling moves the "+" (`clipScrolled`), observed only while `tracksCommentHover`.
    private weak var scrollObservedClip: NSClipView?

    /// Follows the clip view's scrolling only while the pointer is tracked: every other table adds no observer (and no
    /// `scrollWheel` override, which would cost AppKit's responsive scrolling).
    private func observeClipScroll() {
        if let scrollObservedClip {
            NotificationCenter.default.removeObserver(self, name: NSView.boundsDidChangeNotification,
                                                      object: scrollObservedClip)
        }
        scrollObservedClip = nil
        guard tracksCommentHover, let clip = enclosingScrollView?.contentView else { return }
        clip.postsBoundsChangedNotifications = true
        NotificationCenter.default.addObserver(self, selector: #selector(clipScrolled),
                                               name: NSView.boundsDidChangeNotification, object: clip)
        scrollObservedClip = clip
    }

    /// The rows moved under a still pointer: the "+" follows to the line now under it.
    @objc private func clipScrolled() {
        guard tracksCommentHover, let window, window.isKeyWindow else { return }
        let point = convert(window.mouseLocationOutsideOfEventStream, from: nil)
        controller?.hoverComment(at: visibleRect.contains(point) ? point : nil)
    }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        // In a hidden tab it waits until the tab shows (`WindowModel.focusShownTab`).
        guard let window, !tookFocus, !isHiddenOrHasHiddenAncestor else { return }
        tookFocus = true
        // The other tables of the same diff do not steal it; a hidden tab's table does not keep it.
        if let focused = window.firstResponder as? DiffTableView, !focused.isHiddenOrHasHiddenAncestor { return }
        if window.makeFirstResponder(self) { UITiming.focus(repo, "diff") }
    }

    /// A table lets only a selected row's views take the keyboard, and the comment box's row is never selected: its
    /// text (and buttons) take it anyway, so a click back into the box types there (and Esc cancels the box instead of
    /// closing the file).
    override func validateProposedFirstResponder(_ responder: NSResponder, for event: NSEvent?) -> Bool {
        var view = responder as? NSView
        while let current = view, current !== self {
            if current is DiffComposerCellView { return true }
            view = current.superview
        }
        return super.validateProposedFirstResponder(responder, for: event)
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

    /// In a line's text: a click selects the line (as in the gutter), a drag selects text, a double click a word and a
    /// triple click the line's text. Anywhere else, or with ⇧ or ⌘, the table selects lines.
    override func mouseDown(with event: NSEvent) {
        let point = convert(event.locationInWindow, from: nil)
        guard let controller, event.modifierFlags.intersection([.shift, .command, .control]).isEmpty,
              let hit = controller.textHit(at: point)
        else {
            controller?.clearTextSelection()
            return super.mouseDown(with: event)
        }
        let (start, column) = hit
        if event.clickCount > 1 {
            window?.makeFirstResponder(self)
            controller.selectWord(at: start, column: column, wholeLine: event.clickCount > 2)
            return
        }
        // A click or a drag: wait for the mouse to go up or to move away.
        while let next = window?.nextEvent(matching: [.leftMouseDragged, .leftMouseUp], until: .distantFuture,
                                           inMode: .eventTracking, dequeue: false) {
            guard next.type == .leftMouseDragged else { break }
            let moved = convert(next.locationInWindow, from: nil)
            if hypot(moved.x - point.x, moved.y - point.y) >= 3 {
                window?.makeFirstResponder(self)
                controller.beginTextSelection(at: start, column: column)
                trackTextDrag(from: next)
                return
            }
            _ = window?.nextEvent(matching: .leftMouseDragged)
        }
        controller.clearTextSelection()
        super.mouseDown(with: event)
    }

    /// Follows the drag until the mouse goes up, scrolling while it is past the edge (periodic events keep it going
    /// while the mouse holds still there).
    private func trackTextDrag(from event: NSEvent) {
        NSEvent.startPeriodicEvents(afterDelay: 0.05, withPeriod: 0.05)
        defer { NSEvent.stopPeriodicEvents() }
        var last = event
        repeat {
            autoscroll(with: last)
            controller?.extendTextSelection(to: convert(last.locationInWindow, from: nil))
            guard let next = window?.nextEvent(matching: [.leftMouseDragged, .leftMouseUp, .periodic]),
                  next.type != .leftMouseUp
            else { return }
            if next.type == .leftMouseDragged { last = next }
        } while true
    }

    /// An I-beam over the lines' text.
    override func resetCursorRects() {
        super.resetCursorRects()
        for rect in controller?.textRects(in: visibleRect) ?? [] {
            addCursorRect(rect, cursor: .iBeam)
        }
    }

    override func menu(for event: NSEvent) -> NSMenu? {
        controller?.menu(at: row(at: convert(event.locationInWindow, from: nil)))
    }
}

/// Which line of a row a text selection reads: a unified row's line, or one half of a split row.
enum DiffTextColumn {
    case unified, old, new
}

/// A place in a diff's text: a row, and an offset (UTF-16) in its line's text.
struct DiffTextPoint: Comparable {
    var row: Int
    var offset: Int

    static func < (lhs: Self, rhs: Self) -> Bool {
        (lhs.row, lhs.offset) < (rhs.row, rhs.offset)
    }
}

/// Text selected by a drag, from where it started (`anchor`) to where the mouse is (`head`), on one column.
struct DiffTextSelection {
    let column: DiffTextColumn
    var anchor: DiffTextPoint
    var head: DiffTextPoint

    var start: DiffTextPoint { min(anchor, head) }
    var end: DiffTextPoint { max(anchor, head) }

    /// The selected part of `row`'s line, whose text is `length` long; nil when none of it is.
    func part(row: Int, length: Int) -> DiffLineDrawing.Selection? {
        let start = start
        let end = end
        guard start.row <= row, row <= end.row else { return nil }
        let lower = row == start.row ? min(start.offset, length) : 0
        let upper = row == end.row ? min(end.offset, length) : length
        let throughEnd = row < end.row
        guard upper > lower || throughEnd else { return nil }
        return DiffLineDrawing.Selection(range: NSRange(location: lower, length: max(0, upper - lower)),
                                         throughEnd: throughEnd)
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
    /// Text selected by a drag; it and the selected lines never go together.
    private var textSelection: DiffTextSelection?
    /// The threads the rows hold (`DiffLineTable.inlineThreads`), the ones shown collapsed, the rows they are in, and
    /// the ones whose line is not in the rows (none of their own).
    private var shownThreads: [DiffInlineThread] = []
    private var collapsedThreads: Set<Int> = []
    private var threadRows = IndexSet()
    private var unplacedThreads: [Int] = []
    /// The hidden comments whose text their Show toggle showed here, by comment id.
    private var revealedComments: Set<Int> = []
    /// Expanded threads' heights by thread id, for `threadHeightsWidth` (the width their boxes were laid out at).
    private var threadHeights: [Int: CGFloat] = [:]
    private var threadHeightsWidth: CGFloat = -1
    /// The new comment box the rows hold (`DiffNewComments.composer`) and its row; the "+" over the hovered line.
    private var shownComposer: DiffInlineComposer?
    private var composerRow: Int?
    private var commentButton: DiffCommentButton?

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
    private static let threadID = NSUserInterfaceItemIdentifier("diffThread")
    private static let composerID = NSUserInterfaceItemIdentifier("diffComposer")

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
        // Always empty outside a pull request's Files changed.
        let threads = view.inlineThreads?.threads ?? []
        let newComments = view.inlineThreads?.newComments
        table.tracksCommentHover = newComments != nil
        if newComments == nil { commentButton?.isHidden = true }
        if key != shown || threads != shownThreads || newComments?.composer != shownComposer {
            let modeChanged = shown.map { $0.mode != key.mode } ?? false
            // A table that just appeared takes the press before it as seen.
            if shown == nil { jumpSerial = view.jump?.serial }
            shown = key
            shownThreads = threads
            shownComposer = newComments?.composer
            collapsedThreads = view.inlineThreads?.collapsed ?? []
            // Read before the rows change: the box's row is the shown one's.
            let wasTyping = composerHasFocus()
            placeRows(view)
            layout = DiffLayout(rows: view.section.rows(view.mode),
                                oneGutter: [.untracked, .file].contains(view.section.side))
            heightsWidth = -1
            textSelection = nil
            // A reload after a stage keeps the scroll offset; the selection goes (its lines may be gone).
            // `reloadData` keeps the selected row indexes, which would now point at other lines, so clear them.
            table.reloadData()
            table.deselectAll(nil)
            commentButton?.isHidden = true
            // The box closed (Esc, Cancel, Comment): give the keyboard back to the table, not the window.
            if wasTyping, composerRow == nil {
                table.window?.makeFirstResponder(table)
            } else if wasTyping {
                focusComposer()
            }
            table.contentWidth = view.wraps || view.mode == .split ? 0 : layout.contentWidth
            table.tile()
            // The I-beam follows the new rows' text.
            table.window?.invalidateCursorRects(for: table)
            if modeChanged { scrollToFirstChange(table) }
            #if DEBUG
            logProbe(table)
            runLaunchStage()
            #endif
        } else {
            refreshHunkButtons()
            let collapsed = view.inlineThreads?.collapsed ?? []
            for id in collapsed.symmetricDifference(collapsedThreads) {
                setCollapsed(id, collapsed.contains(id))
            }
            // Comment follows the pull request's running action.
            if let composerRow, let cell = table.view(atColumn: 0, row: composerRow, makeIfNecessary: false)
                as? DiffComposerCellView { cell.setBusy(newComments?.isBusy == true) }
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

    /// The table with the keyboard focus, else the file's first table. A hidden tab's table with the focus counts as
    /// none.
    private func isJumpTarget(_ table: NSTableView, _ view: DiffLineTable) -> Bool {
        guard let responder = table.window?.firstResponder as? DiffTableView, !responder.isHiddenOrHasHiddenAncestor
        else { return view.isFirst }
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

    // MARK: Threads

    /// The section's rows, with the threads and the new comment box under their lines when there are any (never
    /// outside a pull request's Files changed).
    private func placeRows(_ view: DiffLineTable) {
        rows = view.section.tableRows(view.mode)
        threadRows = []
        unplacedThreads = []
        threadHeights = [:]
        composerRow = nil
        if !shownThreads.isEmpty || shownComposer != nil { placeThreads(shownThreads) }
    }

    /// Puts each thread in a row right after the row of its line on its side (a context line has both sides), several
    /// on one line in their order, then the new comment box under its line; a thread whose line is not in the rows
    /// gets none.
    private func placeThreads(_ threads: [DiffInlineThread]) {
        var newSide: [Int: [DiffInlineThread]] = [:]
        var oldSide: [Int: [DiffInlineThread]] = [:]
        for thread in threads {
            if thread.newSide {
                newSide[thread.line, default: []].append(thread)
            } else {
                oldSide[thread.line, default: []].append(thread)
            }
        }
        var placed: [DiffTableRow] = []
        placed.reserveCapacity(rows.count + threads.count)
        for row in rows {
            placed.append(row)
            for line in row.lines {
                var here: [DiffInlineThread] = []
                if line.kind != .added, let number = line.oldLine { here += oldSide.removeValue(forKey: number) ?? [] }
                if line.kind != .removed, let number = line.newLine { here += newSide.removeValue(forKey: number) ?? [] }
                for thread in here {
                    threadRows.insert(placed.count)
                    placed.append(.thread(thread))
                }
            }
            if let composer = shownComposer, composerRow == nil, case .single(let line) = row,
               DiffInlineLine(line) == composer.end {
                composerRow = placed.count
                placed.append(.composer(composer))
            }
        }
        rows = placed
        unplacedThreads = threads.map(\.id).filter { id in
            !threadRows.contains { if case .thread(let thread) = rows[$0] { thread.id == id } else { false } }
        }
    }

    /// The width a thread's box lays out in: the card's visible width (the column is wider when a long line scrolls
    /// sideways), as `DiffThreadCellView` draws it; 0 until the card is laid out.
    private var threadWidth: CGFloat {
        table?.enclosingScrollView?.contentView.bounds.width ?? 0
    }

    /// A thread row's height: its header alone when collapsed, else its whole box at `threadWidth`.
    private func threadHeight(_ thread: DiffInlineThread) -> CGFloat {
        if collapsedThreads.contains(thread.id) { return DiffThreadDrawing.collapsedHeight }
        let width = threadWidth
        // Not laid out yet: a header's height, measured once the card has its width (`widthChanged`).
        guard width > 0 else { return DiffThreadDrawing.collapsedHeight }
        if abs(width - threadHeightsWidth) > 0.5 {
            threadHeights = [:]
            threadHeightsWidth = width
        }
        if let height = threadHeights[thread.id] { return height }
        let height = DiffThreadDrawing.height(thread, width: width, revealed: revealedComments)
        threadHeights[thread.id] = height
        return height
    }

    private func configure(_ cell: DiffThreadCellView, _ thread: DiffInlineThread) {
        cell.configure(thread, collapsed: collapsedThreads.contains(thread.id),
                       onToggle: { [weak self] in self?.toggleThread(thread.id) },
                       onReply: { [weak self] in self?.view?.inlineThreads?.onReply() },
                       replyTitle: view?.inlineThreads?.replyTitle ?? "Reply in Conversation",
                       revealed: revealedComments,
                       onReveal: { [weak self] in self?.toggleRevealed($0, in: thread.id) })
    }

    /// A hidden comment's Show or Hide: its text shows or goes at once, its thread's row taking the new height.
    private func toggleRevealed(_ commentID: Int, in threadID: Int) {
        if revealedComments.remove(commentID) == nil { revealedComments.insert(commentID) }
        threadHeights[threadID] = nil
        guard let table, let index = threadRows.first(where: { index in
            if case .thread(let thread) = rows[index] { thread.id == threadID } else { false }
        }), case .thread(let thread) = rows[index] else { return }
        NSAnimationContext.runAnimationGroup { context in
            context.duration = 0
            table.noteHeightOfRows(withIndexesChanged: IndexSet(integer: index))
        }
        if let cell = table.view(atColumn: 0, row: index, makeIfNecessary: false) as? DiffThreadCellView {
            configure(cell, thread)
        }
    }

    /// A header click: the thread collapses or expands at once, then the owner keeps the choice.
    private func toggleThread(_ id: Int) {
        let collapsed = !collapsedThreads.contains(id)
        setCollapsed(id, collapsed)
        view?.inlineThreads?.onToggle(id, collapsed)
    }

    /// Shows thread `id` collapsed or expanded: its row's height and its cell, without reloading the table.
    private func setCollapsed(_ id: Int, _ collapsed: Bool) {
        if collapsed { collapsedThreads.insert(id) } else { collapsedThreads.remove(id) }
        guard let table, let index = threadRows.first(where: { index in
            if case .thread(let thread) = rows[index] { thread.id == id } else { false }
        }), case .thread(let thread) = rows[index] else { return }
        NSAnimationContext.runAnimationGroup { context in
            context.duration = 0
            table.noteHeightOfRows(withIndexesChanged: IndexSet(integer: index))
        }
        if let cell = table.view(atColumn: 0, row: index, makeIfNecessary: false) as? DiffThreadCellView {
            configure(cell, thread)
        }
        #if DEBUG
        UITiming.probe("diff-probe", "thread \(id) \(collapsed ? "collapsed" : "expanded") "
            + "height \(Int(table.rect(ofRow: index).height))")
        #endif
    }

    // MARK: New comments

    /// The line a "+" can comment on: a unified row's line (the pull request's Files changed is never split).
    private func commentLine(_ row: Int) -> DiffInlineLine? {
        guard rows.indices.contains(row), case .single(let line) = rows[row] else { return nil }
        return DiffInlineLine(line)
    }

    /// The row showing `line`.
    private func row(of line: DiffInlineLine) -> Int? {
        rows.indices.first { index in
            if case .single(let row) = rows[index] { DiffInlineLine(row) == line } else { false }
        }
    }

    /// The pointer moved over the table (nil: it left it): the "+" goes to the line under it, or hides.
    func hoverComment(at point: NSPoint?) {
        guard let table, view?.inlineThreads?.newComments != nil, let point,
              case let index = table.row(at: point), index >= 0, commentLine(index) != nil
        else {
            commentButton?.isHidden = true
            return
        }
        let button = commentButton ?? {
            let button = DiffCommentButton()
            button.onPress = { [weak self] row, shift in self?.commentPressed(row: row, shift: shift) }
            commentButton = button
            return button
        }()
        let rect = table.rect(ofRow: index)
        let side = min(18, max(12, DiffLayout.lineHeight - 2))
        button.row = index
        button.frame = NSRect(x: rect.minX + layout.signX - 7,
                              y: rect.minY + (min(rect.height, DiffLayout.lineHeight) - side) / 2,
                              width: side, height: side)
        if table.subviews.last !== button {
            // Above the row views, which the table adds as it scrolls.
            table.addSubview(button, positioned: .above, relativeTo: nil)
        }
        button.isHidden = false
        table.window?.invalidateCursorRects(for: button)
    }

    /// A "+" click on `row`: the box opens under it (a box already open elsewhere in the file moves there, its text
    /// kept); with ⇧ and an open box, the lines from the box's first line to this one make a range, unless they cross
    /// a hunk or the host refuses it (the box stays, saying why). Shown at once, then the owner keeps it.
    private func commentPressed(row index: Int, shift: Bool) {
        guard let newComments = view?.inlineThreads?.newComments, let line = commentLine(index) else { return }
        var composer = DiffInlineComposer(end: line)
        if shift, newComments.allowsRange, let open = shownComposer, let anchor = row(of: open.start ?? open.end),
           anchor != index {
            let first = min(anchor, index), last = max(anchor, index)
            if let start = commentLine(first), let end = commentLine(last) {
                if rows[first...last].contains(where: { $0.hunk != nil }) {
                    composer = open
                    composer.message = "A range stays in one hunk."
                } else if let refusal = newComments.refusal(start, end) {
                    composer = open
                    composer.message = refusal
                } else {
                    composer = DiffInlineComposer(end: end, start: start)
                }
            }
        }
        showComposer(composer)
        newComments.onOpen(composer)
    }

    /// Puts `composer` in the rows now (the click's own update), its text field focused.
    private func showComposer(_ composer: DiffInlineComposer) {
        guard let view, let table else { return }
        shownComposer = composer
        placeRows(view)
        heightsWidth = -1
        textSelection = nil
        table.reloadData()
        table.deselectAll(nil)
        commentButton?.isHidden = true
        focusComposer()
        #if DEBUG
        UITiming.probe("diff-probe", "composer open " + composerSummary())
        #endif
    }

    private func configure(_ cell: DiffComposerCellView, _ composer: DiffInlineComposer) {
        guard let newComments = view?.inlineThreads?.newComments else { return }
        cell.configure(composer, text: newComments.draft(), busy: newComments.isBusy,
                       onDraft: { [weak self] in self?.view?.inlineThreads?.newComments?.onDraft($0) },
                       onCancel: { [weak self] in self?.view?.inlineThreads?.newComments?.onCancel() },
                       onPost: { [weak self] in self?.view?.inlineThreads?.newComments?.onPost($0) },
                       commentTitle: newComments.commentTitle,
                       review: newComments.review.map { review in
                           (review.title, { [weak self] in self?.view?.inlineThreads?.newComments?.review?.onPost($0) })
                       },
                       suggestion: newComments.suggestion.flatMap { block in suggestionLines(composer).map(block) })
    }

    /// The text of the box's new-side lines (added or unchanged; removed ones in between skipped), what "Suggest a
    /// change" puts in its block; nil when its first or last line is a removed one (or it is not shown).
    private func suggestionLines(_ composer: DiffInlineComposer) -> [String]? {
        guard composer.end.kind != .removed, composer.start?.kind != .removed, let last = row(of: composer.end)
        else { return nil }
        let first = composer.start.flatMap(row(of:)) ?? last
        guard first <= last else { return nil }
        let lines = rows[first...last].compactMap { row -> String? in
            guard case .single(let line) = row, line.kind == .added || line.kind == .context else { return nil }
            return line.text
        }
        return lines.isEmpty ? nil : lines
    }

    private var composerCell: DiffComposerCellView? {
        guard let table, let composerRow else { return nil }
        return table.view(atColumn: 0, row: composerRow, makeIfNecessary: false) as? DiffComposerCellView
    }

    /// Whether the user is typing in the box (its text field has the keyboard).
    private func composerHasFocus() -> Bool {
        composerCell?.hasFocus == true
    }

    /// The box's text field takes the keyboard (scrolled into view first, so its cell exists).
    private func focusComposer() {
        guard let table, let composerRow else { return }
        table.scrollRowToVisible(composerRow)
        (table.view(atColumn: 0, row: composerRow, makeIfNecessary: true) as? DiffComposerCellView)?.focus()
    }

    // MARK: Data

    func numberOfRows(in tableView: NSTableView) -> Int { rows.count }

    func tableView(_ tableView: NSTableView, heightOfRow row: Int) -> CGFloat {
        guard rows.indices.contains(row) else { return DiffLayout.lineHeight }
        if case .thread(let thread) = rows[row] { return threadHeight(thread) }
        if case .composer = rows[row] { return DiffComposerCellView.height }
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
            // Measured on its own (`threadHeight`): it does not wrap with the lines.
            case .thread, .composer:
                0
            }
        }
    }

    /// The column got wider or narrower: wrapped rows are measured again (after this layout pass), and thread rows
    /// when the card's visible width changed.
    func widthChanged() {
        if !threadRows.isEmpty, threadWidth > 0, abs(threadWidth - threadHeightsWidth) > 0.5 {
            DispatchQueue.main.async { [weak self] in
                guard let self, let table, !threadRows.isEmpty, threadWidth > 0,
                      abs(threadWidth - threadHeightsWidth) > 0.5
                else { return }
                // Taken now, so a layout pass the new heights start does not come back here for the same width.
                threadHeights = [:]
                threadHeightsWidth = threadWidth
                NSAnimationContext.runAnimationGroup { context in
                    context.duration = 0
                    table.noteHeightOfRows(withIndexesChanged: threadRows)
                }
                #if DEBUG
                UITiming.probe("diff-probe", threadSummary(table))
                #endif
            }
        }
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
            cell.selection = selectionPart(row: row, column: .unified)
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
            cell.oldSelection = selectionPart(row: row, column: .old)
            cell.newSelection = selectionPart(row: row, column: .new)
            cell.needsDisplay = true
            return cell
        case .thread(let thread):
            let cell = tableView.makeView(withIdentifier: Self.threadID, owner: nil) as? DiffThreadCellView ?? {
                let cell = DiffThreadCellView()
                cell.identifier = Self.threadID
                return cell
            }()
            configure(cell, thread)
            return cell
        case .composer(let composer):
            let cell = tableView.makeView(withIdentifier: Self.composerID, owner: nil) as? DiffComposerCellView ?? {
                let cell = DiffComposerCellView()
                cell.identifier = Self.composerID
                return cell
            }()
            configure(cell, composer)
            return cell
        }
    }

    /// Hunk headers are not lines: a click or a drag never selects them.
    func tableView(_ tableView: NSTableView, selectionIndexesForProposedSelection proposed: IndexSet) -> IndexSet {
        proposed.filteredIndexSet { rows.indices.contains($0) && rows[$0].isLine }
    }

    func tableViewSelectionDidChange(_ notification: Notification) {
        // Lines selected (by a click or the arrow keys): the text selection goes.
        if table?.selectedRowIndexes.isEmpty == false { clearTextSelection() }
        refreshHunkButtons()
    }

    // MARK: Text selection

    /// The line `row` shows on `column`: a unified row's line, or a split row's old or new line (nil for a hunk
    /// header or an empty half).
    private func line(_ row: Int, _ column: DiffTextColumn) -> DiffRow? {
        guard rows.indices.contains(row) else { return nil }
        switch rows[row] {
        case .single(let line): return line.isLine ? line : nil
        case .pair(let old, let new): return column == .new ? new : old
        case .thread, .composer: return nil
        }
    }

    /// Where the text of `row` starts on `column`, in the table, and the width it wraps at (nil: one line). The
    /// same spots as `DiffLineCellView` and `DiffSplitCellView` draw it at.
    private func textOrigin(row: Int, column: DiffTextColumn) -> (NSPoint, CGFloat?)? {
        guard let table, rows.indices.contains(row) else { return nil }
        let cell = table.frameOfCell(atColumn: 0, row: row)
        let wraps = view?.wraps == true
        let y = cell.minY + (wraps ? DiffLayout.wrapPadding / 2 : 0)
        switch rows[row] {
        case .single:
            return (NSPoint(x: cell.minX + layout.textX, y: y),
                    wraps ? layout.wrapWidth(rowWidth: cell.width, split: false) : nil)
        case .pair:
            let half = column == .new ? (cell.width / 2).rounded(.down) : 0
            return (NSPoint(x: cell.minX + half + layout.splitTextX, y: y),
                    wraps ? layout.wrapWidth(rowWidth: cell.width, split: true) : nil)
        case .thread, .composer:
            return nil
        }
    }

    /// The offset in `row`'s line on `column` nearest `point` (in the table).
    private func offset(at point: NSPoint, row: Int, column: DiffTextColumn) -> Int {
        guard let line = line(row, column), let text = textOrigin(row: row, column: column) else { return 0 }
        return DiffLineDrawing.offset(at: NSPoint(x: point.x - text.0.x, y: point.y - text.0.y), in: line.text,
                                      wrapWidth: text.1)
    }

    /// The place in a line's text under `point`, and its column; nil outside the text (the gutters, a hunk header,
    /// an empty half of a split row).
    func textHit(at point: NSPoint) -> (DiffTextPoint, DiffTextColumn)? {
        guard let table else { return nil }
        let row = table.row(at: point)
        guard rows.indices.contains(row) else { return nil }
        let column: DiffTextColumn
        if case .pair = rows[row] {
            let cell = table.frameOfCell(atColumn: 0, row: row)
            column = point.x < cell.minX + (cell.width / 2).rounded(.down) ? .old : .new
        } else {
            column = .unified
        }
        guard line(row, column) != nil, let text = textOrigin(row: row, column: column), point.x >= text.0.x
        else { return nil }
        return (DiffTextPoint(row: row, offset: offset(at: point, row: row, column: column)), column)
    }

    func beginTextSelection(at point: DiffTextPoint, column: DiffTextColumn) {
        table?.deselectAll(nil)
        setTextSelection(DiffTextSelection(column: column, anchor: point, head: point))
    }

    /// Moves the selection's end to `point`: above the first row it is the start, under the last the end, on a hunk
    /// header or an empty half the start of that row.
    func extendTextSelection(to point: NSPoint) {
        guard let table, var selection = textSelection, !rows.isEmpty else { return }
        let row = table.row(at: NSPoint(x: table.bounds.minX + 1, y: point.y))
        if row >= 0 {
            selection.head = DiffTextPoint(row: row, offset: offset(at: point, row: row, column: selection.column))
        } else if point.y < table.rect(ofRow: 0).minY {
            selection.head = DiffTextPoint(row: 0, offset: 0)
        } else {
            let last = rows.count - 1
            selection.head = DiffTextPoint(row: last, offset: line(last, selection.column)?.text.utf16.count ?? 0)
        }
        setTextSelection(selection)
    }

    /// A double click: the word at `point`; a triple click: the line's whole text.
    func selectWord(at point: DiffTextPoint, column: DiffTextColumn, wholeLine: Bool) {
        guard let line = line(point.row, column) else { return }
        let word = DiffLineDrawing.word(at: point.offset, in: line.text, wholeLine: wholeLine)
        table?.deselectAll(nil)
        setTextSelection(DiffTextSelection(column: column, anchor: DiffTextPoint(row: point.row, offset: word.location),
                                           head: DiffTextPoint(row: point.row, offset: NSMaxRange(word))))
    }

    func clearTextSelection() {
        if textSelection != nil { setTextSelection(nil) }
    }

    private func setTextSelection(_ selection: DiffTextSelection?) {
        textSelection = selection
        guard let table else { return }
        let visible = table.rows(in: table.visibleRect)
        for index in visible.location..<NSMaxRange(visible) {
            switch table.view(atColumn: 0, row: index, makeIfNecessary: false) {
            case let cell as DiffLineCellView:
                cell.selection = selectionPart(row: index, column: .unified)
            case let cell as DiffSplitCellView:
                cell.oldSelection = selectionPart(row: index, column: .old)
                cell.newSelection = selectionPart(row: index, column: .new)
            default:
                break
            }
        }
    }

    /// The selected part of `row`'s line on `column`.
    private func selectionPart(row: Int, column: DiffTextColumn) -> DiffLineDrawing.Selection? {
        guard let selection = textSelection, selection.column == column, let line = line(row, column) else { return nil }
        return selection.part(row: row, length: line.text.utf16.count)
    }

    /// The selected text: each line's selected part, one per line (no numbers, no `+`/`−`); nil when none.
    private func selectedText() -> String? {
        guard let selection = textSelection, selection.start != selection.end else { return nil }
        var parts: [String] = []
        for row in selection.start.row...selection.end.row {
            guard let line = line(row, selection.column),
                  let part = selection.part(row: row, length: line.text.utf16.count)
            else { continue }
            parts.append((line.text as NSString).substring(with: part.range))
        }
        return parts.isEmpty ? nil : parts.joined(separator: "\n")
    }

    /// The lines' text areas among the rows in `rect` (for the I-beam).
    func textRects(in rect: NSRect) -> [NSRect] {
        guard let table else { return [] }
        let range = table.rows(in: rect)
        return (range.location..<NSMaxRange(range)).flatMap { row -> [NSRect] in
            guard rows.indices.contains(row) else { return [] }
            let cell = table.frameOfCell(atColumn: 0, row: row)
            switch rows[row] {
            case .single(let line):
                guard line.isLine else { return [] }
                return [NSRect(x: cell.minX + layout.textX, y: cell.minY,
                               width: max(0, cell.width - layout.textX), height: cell.height)]
            case .pair(let old, let new):
                let half = (cell.width / 2).rounded(.down)
                var rects: [NSRect] = []
                if old != nil {
                    rects.append(NSRect(x: cell.minX + layout.splitTextX, y: cell.minY,
                                        width: max(0, half - layout.splitTextX), height: cell.height))
                }
                if new != nil {
                    rects.append(NSRect(x: cell.minX + half + layout.splitTextX, y: cell.minY,
                                        width: max(0, cell.width - half - layout.splitTextX), height: cell.height))
                }
                return rects
            case .thread, .composer:
                return []
            }
        }
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
    /// read-only diff (a stash or a compare, a merge's combined diff, an untracked file, whitespace
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

    /// The side's actions, and Revert for a commit's diff. Not in Full file: its one hunk has
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

    /// The selected text; else the selected lines, whole, one per line (no `+`/`−`, no line numbers; a split row's old
    /// line, then its new one).
    func copySelection() {
        guard let table else { return }
        if let text = selectedText() {
            NSPasteboard.general.clearContents()
            NSPasteboard.general.setString(text, forType: .string)
            return
        }
        let lines = table.selectedRowIndexes.flatMap { rows.indices.contains($0) ? rows[$0].lines.map(\.text) : [] }
        guard !lines.isEmpty else { return }
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(lines.joined(separator: "\n") + "\n", forType: .string)
    }

    /// A right-click on a line: it joins the selection (or replaces it when it was not selected), then Copy and the
    /// side's actions on the selected lines.
    func menu(at row: Int) -> NSMenu? {
        guard let table, let view, rows.indices.contains(row), rows[row].isLine else { return nil }
        // On selected text: Copy copies it, and the selection stays.
        if let selection = textSelection, selectedText() != nil,
           (selection.start.row...selection.end.row).contains(row) {
            return MenuBuilder.menu([.action("Copy") { [weak self] in self?.copySelection() }])
        }
        clearTextSelection()
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
    /// The rows a load put in the table: `diff-probe <side> <mode> rows <n> hunks <n> height <points> width <points>`
    /// (the regression check of the shared table: the same for the same diff).
    private func logProbe(_ table: NSTableView) {
        guard let view else { return }
        let hunks = rows.count { $0.hunk != nil }
        let height = rows.isEmpty ? 0 : table.rect(ofRow: rows.count - 1).maxY
        // A pull request's file adds its threads; every other table logs the same line as before them.
        UITiming.probe("diff-probe", "\(view.section.side) \(view.mode.rawValue) rows \(rows.count) hunks \(hunks) "
            + "height \(Int(height)) width \(Int(rowWidth))"
            + (view.inlineThreads == nil ? "" : " " + threadSummary(table))
            + (shownComposer == nil ? "" : " composer " + composerSummary()))
    }

    /// `under <R|L><line>[ from <R|L><line>] row <index> h<height> text <characters>[ refused]`: where the new comment
    /// box is, and how much text it holds.
    private func composerSummary() -> String {
        guard let composer = shownComposer else { return "none" }
        let height = composerRow.flatMap { row in table.map { Int($0.rect(ofRow: row).height) } }
        return "under \(composer.end.probe)" + (composer.start.map { " from \($0.probe)" } ?? "")
            + " row \(composerRow.map(String.init) ?? "none") h\(height.map(String.init) ?? "?")"
            + " text \(view?.inlineThreads?.newComments?.draft().count ?? 0)"
            + (composer.message == nil ? "" : " refused")
    }

    /// `threads <path> width <points> placed <id>@<R|L><line>[ collapsed] h<height>,… unplaced <id>,…` (the rows
    /// placed, under which line of which side, and their heights).
    private func threadSummary(_ table: NSTableView) -> String {
        let placed = threadRows.compactMap { index -> String? in
            guard case .thread(let thread) = rows[index] else { return nil }
            return "\(thread.id)@\(thread.newSide ? "R" : "L")\(thread.line)"
                + (collapsedThreads.contains(thread.id) ? " collapsed" : "") + " h\(Int(table.rect(ofRow: index).height))"
        }
        return "threads \(view?.inlineThreads?.path ?? "?") width \(Int(threadWidth)) "
            + "placed \(placed.isEmpty ? "none" : placed.joined(separator: ","))"
            + " unplaced \(unplacedThreads.isEmpty ? "none" : unplacedThreads.map(String.init).joined(separator: ","))"
    }

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

/// The syntax token colors, shared by the diff lines, the blame view and the file editor.
@MainActor
enum SyntaxColors {
    static func color(_ kind: TokenKind) -> NSColor {
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

    /// The selected part of a line's text, and whether the selection goes on past its end (to the next line).
    struct Selection: Equatable {
        var range: NSRange
        var throughEnd: Bool
    }

    /// `text` laid out as it draws: one line, or wrapped at `wrapWidth`. The storage owns the layout manager.
    private static func textLayout(_ text: String, wrapWidth: CGFloat?) -> (NSTextStorage, NSLayoutManager, NSTextContainer) {
        let storage = NSTextStorage(string: text, attributes: wrapWidth == nil ? style.text : style.wrappedText)
        let manager = NSLayoutManager()
        let container = NSTextContainer(size: NSSize(width: wrapWidth ?? .greatestFiniteMagnitude,
                                                     height: .greatestFiniteMagnitude))
        // String drawing lays text out without padding.
        container.lineFragmentPadding = 0
        manager.addTextContainer(container)
        storage.addLayoutManager(manager)
        manager.ensureLayout(for: container)
        return (storage, manager, container)
    }

    /// The offset in `text` (UTF-16, between two characters) nearest `point`, from the text's top left corner.
    static func offset(at point: NSPoint, in text: String, wrapWidth: CGFloat?) -> Int {
        guard !text.isEmpty else { return 0 }
        let (storage, manager, container) = textLayout(text, wrapWidth: wrapWidth)
        var fraction: CGFloat = 0
        let index = manager.characterIndex(for: NSPoint(x: point.x, y: wrapWidth == nil ? 1 : point.y), in: container,
                                           fractionOfDistanceBetweenInsertionPoints: &fraction)
        guard index < storage.length else { return storage.length }
        let character = (storage.string as NSString).rangeOfComposedCharacterSequence(at: index)
        return fraction > 0.5 ? NSMaxRange(character) : character.location
    }

    /// The word around `offset` (a double click), or the whole line (`wholeLine`, a triple click).
    static func word(at offset: Int, in text: String, wholeLine: Bool) -> NSRange {
        let length = text.utf16.count
        guard !wholeLine, length > 0 else { return NSRange(location: 0, length: length) }
        return NSAttributedString(string: text).doubleClick(at: min(offset, length - 1))
    }

    /// The selection's rects, from the text's top left corner: a rect per wrapped line it covers, and a character-wide
    /// mark after the text when it goes on to the next line (so a selected empty line shows).
    private static func selectionRects(_ selection: Selection, in text: String, wrapWidth: CGFloat?) -> [NSRect] {
        let (storage, manager, container) = textLayout(text, wrapWidth: wrapWidth)
        let range = NSIntersectionRange(selection.range, NSRange(location: 0, length: storage.length))
        var rects: [NSRect] = []
        if range.length > 0 {
            let glyphs = manager.glyphRange(forCharacterRange: range, actualCharacterRange: nil)
            manager.enumerateEnclosingRects(forGlyphRange: glyphs,
                                            withinSelectedGlyphRange: NSRange(location: NSNotFound, length: 0),
                                            in: container) { rect, _ in rects.append(rect) }
        }
        if selection.throughEnd {
            let height = wrapWidth == nil ? DiffLayout.lineHeight : DiffLayout.wrapLineHeight
            if manager.numberOfGlyphs == 0 {
                rects.append(NSRect(x: 0, y: 0, width: DiffLayout.charWidth, height: height))
            } else {
                let last = manager.lineFragmentUsedRect(forGlyphAt: manager.numberOfGlyphs - 1, effectiveRange: nil)
                rects.append(NSRect(x: last.maxX, y: last.minY, width: DiffLayout.charWidth, height: last.height))
            }
        }
        return rects
    }

    /// Draws `row` in `rect` (a flipped view's coordinates). The numbers and the sign sit on the first line.
    static func draw(_ row: DiffRow, in rect: NSRect, spots: Spots, selection: Selection? = nil) {
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
            text.addAttribute(.foregroundColor, value: SyntaxColors.color(token.kind), range: token.range)
        }
        let emphasisFill = row.kind == .added ? Palette.diffAddedEmphasis : Palette.diffRemovedEmphasis
        if let wrapWidth = spots.wrapWidth {
            // The mark may span lines: a background on the text itself.
            if let emphasis = row.emphasis, NSMaxRange(emphasis) <= length {
                text.addAttribute(.backgroundColor, value: emphasisFill, range: emphasis)
            }
            if let selection {
                // The selection shows over the mark, not under it.
                text.removeAttribute(.backgroundColor, range: NSIntersectionRange(selection.range,
                                                                                 NSRange(location: 0, length: length)))
                Palette.diffTextSelection.setFill()
                for part in selectionRects(selection, in: row.text, wrapWidth: wrapWidth) {
                    part.offsetBy(dx: rect.minX + spots.textX, dy: rect.minY + DiffLayout.wrapPadding / 2).fill()
                }
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
        if let selection {
            // The row's whole height, as the mark.
            Palette.diffTextSelection.setFill()
            for part in selectionRects(selection, in: row.text, wrapWidth: nil) {
                NSRect(x: rect.minX + spots.textX + part.minX, y: rect.minY, width: part.width, height: rect.height).fill()
            }
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
    /// The selected part of its text.
    var selection: DiffLineDrawing.Selection? {
        didSet { if selection != oldValue { needsDisplay = true } }
    }

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
            wrapWidth: wraps ? layout.wrapWidth(rowWidth: bounds.width, split: false) : nil), selection: selection)
    }
}

/// A split row: the old line on the left half (its old number), the new line on the right half (its new number), a
/// thin rule between them. A missing side stays empty; each half clips its own text.
final class DiffSplitCellView: NSView {
    private var old: DiffRow?
    private var new: DiffRow?
    var layout = DiffLayout()
    var wraps = false
    /// The selected part of the old (left) or the new (right) line's text: a selection stays on one side.
    var oldSelection: DiffLineDrawing.Selection? {
        didSet { if oldSelection != oldValue { needsDisplay = true } }
    }
    var newSelection: DiffLineDrawing.Selection? {
        didSet { if newSelection != oldValue { needsDisplay = true } }
    }

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
        for (row, rect, number, selection) in [
            (old, NSRect(x: 0, y: 0, width: half, height: bounds.height), old?.oldLine, oldSelection),
            (new, NSRect(x: half, y: 0, width: bounds.width - half, height: bounds.height), new?.newLine, newSelection),
        ] {
            guard let row else { continue }
            NSGraphicsContext.saveGraphicsState()
            NSBezierPath(rect: rect).addClip()
            DiffLineDrawing.draw(row, in: rect, spots: DiffLineDrawing.Spots(
                numbers: [(number, 0)], numberWidth: layout.numberWidth, signX: layout.numberWidth,
                textX: layout.splitTextX, wrapWidth: wrapWidth), selection: selection)
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
            // Stage is green, Discard a light red (user, 2026-11-17), Revert orange (user, 2026-11-19); Unstage keeps
            // the plain bezel.
            let fill: NSColor? = switch action {
            case .stage: Palette.diffAddedSign.withAlphaComponent(0.5)
            case .discard: Palette.diffRemovedSign.withAlphaComponent(0.3)
            case .revert: Palette.diffRevertTint.withAlphaComponent(0.45)
            case .unstage: nil
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
        Palette.diffHunkEdge.setFill()
        NSRect(x: 0, y: 0, width: bounds.width, height: 1).fill(using: .sourceOver)
        NSRect(x: 0, y: bounds.height - 1, width: bounds.width, height: 1).fill(using: .sourceOver)
    }
}

/// How a thread row lays out, alike when measured (`height`) and drawn (`DiffThreadCellView`): a box inset in the
/// card's visible width, its header (chevron, the line, Resolved; collapsed, also the first author and the count),
/// then each comment (author, date, its body as plain text; a reply indented with a thread line) and the "Reply in
/// Conversation" button. Collapsed, the header only.
@MainActor
enum DiffThreadDrawing {
    static let margin: CGFloat = 6
    static let inset: CGFloat = 8
    static let padding: CGFloat = 8
    static let headerHeight: CGFloat = 20
    static let authorHeight: CGFloat = 16
    static let bodyGap: CGFloat = 2
    static let commentGap: CGFloat = 10
    static let replyIndent: CGFloat = 18
    static let footerGap: CGFloat = 10
    static let footerHeight: CGFloat = 22
    static let collapsedHeight = 2 * margin + 2 * padding + headerHeight

    private static func attributes(_ size: CGFloat, _ weight: NSFont.Weight, _ color: NSColor,
                                   wraps: Bool = false) -> [NSAttributedString.Key: Any] {
        let paragraph = NSMutableParagraphStyle()
        paragraph.lineBreakMode = wraps ? .byWordWrapping : .byTruncatingTail
        return [.font: NSFont.systemFont(ofSize: size, weight: weight), .foregroundColor: color,
                .paragraphStyle: paragraph]
    }

    static let title = attributes(11, .semibold, .secondaryLabelColor)
    static let summaryText = attributes(11, .regular, .secondaryLabelColor)
    static let resolved = attributes(10, .semibold, Palette.diffAddedSign)
    static let pending = attributes(10, .semibold, NSColor(Palette.conflictTone))
    static let author = attributes(12, .semibold, .labelColor)
    static let date = attributes(11, .regular, .secondaryLabelColor)
    static let body = attributes(12, .regular, Palette.diffText, wraps: true)
    static let boxFill = NSColor.white.withAlphaComponent(0.05)
    static let boxEdge = NSColor.white.withAlphaComponent(0.12)
    static let replyLine = NSColor.white.withAlphaComponent(0.15)

    /// The box in a row `width` wide (the card's visible width) and `height` high.
    static func box(width: CGFloat, height: CGFloat) -> NSRect {
        NSRect(x: inset, y: margin, width: max(0, width - 2 * inset), height: max(0, height - 2 * margin))
    }

    /// The width a comment's body wraps at.
    static func textWidth(width: CGFloat, isReply: Bool) -> CGFloat {
        max(40, width - 2 * inset - 2 * padding - (isReply ? replyIndent : 0))
    }

    static func bodyHeight(_ text: NSAttributedString, width: CGFloat) -> CGFloat {
        guard text.length > 0 else { return 0 }
        return text.boundingRect(with: NSSize(width: width, height: .greatestFiniteMagnitude),
                                 options: [.usesLineFragmentOrigin, .usesFontLeading])
            .height.rounded(.up)
    }

    static let suggestionTitle = attributes(11, .semibold, .secondaryLabelColor)
    static let suggestionRemoved = code(Palette.diffRemovedSign)
    static let suggestionAdded = code(Palette.diffAddedSign)

    private static func code(_ color: NSColor) -> [NSAttributedString.Key: Any] {
        let paragraph = NSMutableParagraphStyle()
        paragraph.lineBreakMode = .byCharWrapping
        return [.font: NSFont.monospacedSystemFont(ofSize: 11, weight: .regular), .foregroundColor: color,
                .backgroundColor: color.withAlphaComponent(0.12), .paragraphStyle: paragraph]
    }

    /// A comment's text as drawn, plain (never HTML): its body, then each suggested change as "Suggested change" and
    /// its lines, the replaced ones "− " in red and the new ones "+ " in green; none for a hidden comment whose Show
    /// toggle is closed (`revealed` has not its id).
    static func bodyText(_ comment: DiffInlineThread.Comment, revealed: Set<Int> = []) -> NSAttributedString {
        if comment.hiddenNote != nil, !revealed.contains(comment.id) { return NSAttributedString() }
        let text = NSMutableAttributedString(string: comment.body, attributes: body)
        for suggestion in comment.suggestions {
            if text.length > 0 { text.append(NSAttributedString(string: "\n", attributes: body)) }
            text.append(NSAttributedString(string: "Suggested change", attributes: suggestionTitle))
            for line in suggestion.old {
                text.append(NSAttributedString(string: "\n− " + line, attributes: suggestionRemoved))
            }
            for line in suggestion.new {
                text.append(NSAttributedString(string: "\n+ " + line, attributes: suggestionAdded))
            }
        }
        return text
    }

    /// An expanded thread's row height in a row `width` wide, the hidden comments of `revealed` with their text.
    static func height(_ thread: DiffInlineThread, width: CGFloat, revealed: Set<Int> = []) -> CGFloat {
        thread.comments.reduce(2 * margin + 2 * padding + headerHeight + footerGap + footerHeight) { height, comment in
            height + commentGap + authorHeight + bodyGap
                + bodyHeight(bodyText(comment, revealed: revealed),
                             width: textWidth(width: width, isReply: comment.isReply))
        }
    }

    static let hiddenNote = attributes(11, .regular, .secondaryLabelColor)
    static let revealToggle = attributes(11, .semibold, .linkColor)

    /// "alice · 2 comments": the collapsed header's summary.
    static func summary(_ thread: DiffInlineThread) -> String {
        let count = thread.comments.count
        return [thread.comments.first?.author, count == 1 ? "1 comment" : "\(count) comments"].compactMap { $0 }
            .joined(separator: " · ")
    }
}

/// A review thread under its diff line, drawn natively (`DiffThreadDrawing`); its comments are plain text, never
/// HTML. A click on the header collapses or expands it at once; "Reply in Conversation" goes to the Conversation tab,
/// where replying and resolving are.
final class DiffThreadCellView: NSView {
    private var thread: DiffInlineThread?
    private var collapsed = false
    private var onToggle: (() -> Void)?
    private var onReply: (() -> Void)?
    private var revealed: Set<Int> = []
    private var onReveal: ((Int) -> Void)?
    /// Each hidden comment's Show / Hide as last drawn, by comment id: what a click there toggles.
    private var revealRects: [(id: Int, rect: NSRect)] = []
    private let reply = NSButton(title: "Reply in Conversation", target: nil, action: nil)

    override var isFlipped: Bool { true }
    override var isOpaque: Bool { false }

    override init(frame: NSRect) {
        super.init(frame: frame)
        reply.bezelStyle = .push
        // Every button of the app is a capsule (user, 2026-11-13).
        if #available(macOS 26, *) { reply.borderShape = .capsule }
        reply.controlSize = .small
        reply.font = .systemFont(ofSize: NSFont.systemFontSize(for: .small))
        reply.target = self
        reply.action = #selector(replyPressed)
        addSubview(reply)
        setAccessibilityElement(true)
        setAccessibilityRole(.group)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) is not used") }

    func configure(_ thread: DiffInlineThread, collapsed: Bool, onToggle: @escaping () -> Void,
                   onReply: @escaping () -> Void, replyTitle: String = "Reply in Conversation",
                   revealed: Set<Int> = [], onReveal: ((Int) -> Void)? = nil) {
        if reply.title != replyTitle { reply.title = replyTitle }
        self.thread = thread
        self.collapsed = collapsed
        self.onToggle = onToggle
        self.onReply = onReply
        self.revealed = revealed
        self.onReveal = onReveal
        // A thread the host has not answered yet has no reply row in the Conversation either (`PRPlaceholderID`).
        reply.isHidden = collapsed || PRPlaceholderID.isPlaceholder(thread.id)
        let comments = collapsed ? DiffThreadDrawing.summary(thread)
            : thread.comments.map { comment in
                let text = comment.hiddenNote.map { revealed.contains(comment.id) ? "\($0): \(comment.body)" : $0 }
                return "\(comment.author), \(comment.date): \(text ?? comment.body)"
            }.joined(separator: ". ")
        setAccessibilityLabel("Thread on \(thread.title)\(thread.isResolved ? ", resolved" : ""): \(comments)")
        let toggle = NSAccessibilityCustomAction(name: collapsed ? "Expand" : "Collapse") { [weak self] in
            self?.onToggle?()
            return true
        }
        // Each hidden comment's Show / Hide, as its toggle.
        let hiddenComments = collapsed ? [] : thread.comments.filter { $0.hiddenNote != nil }
        let reveals = hiddenComments.map { comment in
            let shown = revealed.contains(comment.id)
            return NSAccessibilityCustomAction(name: "\(shown ? "Hide" : "Show") \(comment.author)'s hidden comment") {
                [weak self] in
                self?.onReveal?(comment.id)
                return true
            }
        }
        setAccessibilityCustomActions([toggle] + reveals)
        needsLayout = true
        needsDisplay = true
        window?.invalidateCursorRects(for: self)
    }

    /// The card's visible width: the box stays in it when a long line makes the table wider.
    private var visibleWidth: CGFloat {
        let visible = enclosingScrollView?.contentView.bounds.width ?? 0
        return visible > 0 ? min(bounds.width, visible) : bounds.width
    }

    private var box: NSRect { DiffThreadDrawing.box(width: visibleWidth, height: bounds.height) }

    /// What a click toggles: the header (the whole box when collapsed).
    private var headerRect: NSRect {
        let box = box
        let height = DiffThreadDrawing.padding + DiffThreadDrawing.headerHeight
        return collapsed ? box : NSRect(x: box.minX, y: box.minY, width: box.width, height: height)
    }

    override func setFrameSize(_ newSize: NSSize) {
        if newSize != frame.size {
            needsLayout = true
            needsDisplay = true
        }
        super.setFrameSize(newSize)
    }

    override func layout() {
        super.layout()
        guard !collapsed else { return }
        let box = box
        let size = reply.fittingSize
        reply.frame = NSRect(
            x: box.minX + DiffThreadDrawing.padding,
            y: box.maxY - DiffThreadDrawing.padding - (DiffThreadDrawing.footerHeight + size.height) / 2,
            width: size.width, height: size.height)
    }

    @objc private func replyPressed() {
        onReply?()
    }

    override func mouseDown(with event: NSEvent) {
        // Elsewhere in the row nothing happens: a thread is not a line the table selects.
        let point = convert(event.locationInWindow, from: nil)
        if !collapsed, let hit = revealRects.first(where: { $0.rect.contains(point) }) {
            onReveal?(hit.id)
            return
        }
        if headerRect.contains(point) { onToggle?() }
    }

    override func resetCursorRects() {
        addCursorRect(headerRect, cursor: .pointingHand)
    }

    override func draw(_ dirtyRect: NSRect) {
        guard let thread else { return }
        typealias D = DiffThreadDrawing
        let width = visibleWidth
        let box = box
        let shape = NSBezierPath(roundedRect: box.insetBy(dx: 0.5, dy: 0.5), xRadius: 8, yRadius: 8)
        D.boxFill.setFill()
        shape.fill()
        D.boxEdge.setStroke()
        shape.lineWidth = 1
        shape.stroke()

        // The header: chevron, the line, Resolved, and when collapsed who started it and how many comments.
        let headerY = box.minY + D.padding
        var x = box.minX + D.padding
        let right = box.maxX - D.padding
        let chevron = collapsed ? "chevron.right" : "chevron.down"
        let symbol = NSImage(systemSymbolName: chevron, accessibilityDescription: nil)?
            .withSymbolConfiguration(NSImage.SymbolConfiguration(pointSize: 10, weight: .semibold)
                .applying(NSImage.SymbolConfiguration(paletteColors: [.secondaryLabelColor])))
        if let symbol {
            let size = symbol.size
            symbol.draw(in: NSRect(x: x + (12 - size.width) / 2, y: headerY + (D.headerHeight - size.height) / 2,
                                   width: size.width, height: size.height))
        }
        x += 18
        let title = NSAttributedString(string: thread.title, attributes: D.title)
        let titleSize = title.size()
        title.draw(in: NSRect(x: x, y: headerY + (D.headerHeight - titleSize.height) / 2,
                              width: min(titleSize.width, max(0, right - x)), height: titleSize.height))
        x += titleSize.width + 8
        if thread.isResolved, x < right {
            let label = NSAttributedString(string: "✓ Resolved", attributes: D.resolved)
            let size = label.size()
            let capsule = NSRect(x: x, y: headerY + (D.headerHeight - size.height - 4) / 2, width: size.width + 12,
                                 height: size.height + 4)
            Palette.diffAddedSign.withAlphaComponent(0.16).setFill()
            NSBezierPath(roundedRect: capsule, xRadius: capsule.height / 2, yRadius: capsule.height / 2).fill()
            label.draw(at: NSPoint(x: capsule.minX + 6, y: capsule.minY + 2))
            x = capsule.maxX + 8
        }
        revealRects = []
        if collapsed {
            let summary = NSAttributedString(string: D.summary(thread), attributes: D.summaryText)
            let size = summary.size()
            if right - x > 20 {
                summary.draw(in: NSRect(x: x, y: headerY + (D.headerHeight - size.height) / 2, width: right - x,
                                        height: size.height))
            }
            return
        }

        // Each comment: author and date, then its body as plain text; a reply indented, with a thread line.
        var y = headerY + D.headerHeight
        for comment in thread.comments {
            y += D.commentGap
            let left = box.minX + D.padding + (comment.isReply ? D.replyIndent : 0)
            let textWidth = D.textWidth(width: width, isReply: comment.isReply)
            let text = D.bodyText(comment, revealed: revealed)
            let bodyHeight = D.bodyHeight(text, width: textWidth)
            if comment.isReply {
                D.replyLine.setFill()
                NSRect(x: box.minX + D.padding + 5, y: y, width: 2, height: D.authorHeight + D.bodyGap + bodyHeight).fill()
            }
            let author = NSAttributedString(string: comment.author, attributes: D.author)
            var authorWidth = min(author.size().width, textWidth)
            author.draw(in: NSRect(x: left, y: y, width: authorWidth, height: D.authorHeight))
            if comment.isPending, textWidth - authorWidth > 60 {
                // The pending review's capsule, as the Conversation's (`.cap.pending`).
                let label = NSAttributedString(string: "Pending", attributes: D.pending)
                let size = label.size()
                let capsule = NSRect(x: left + authorWidth + 6, y: y + (D.authorHeight - size.height - 2) / 2,
                                     width: size.width + 12, height: size.height + 2)
                let shape = NSBezierPath(roundedRect: capsule.insetBy(dx: 0.5, dy: 0.5), xRadius: capsule.height / 2,
                                         yRadius: capsule.height / 2)
                NSColor(Palette.conflictTone).setStroke()
                shape.lineWidth = 1
                shape.stroke()
                label.draw(at: NSPoint(x: capsule.minX + 6, y: capsule.minY + 1))
                authorWidth = capsule.maxX - left
            }
            if let note = comment.hiddenNote {
                // Hidden on the host: "hidden as <reason>", then its Show / Hide toggle.
                let label = NSAttributedString(string: note, attributes: D.hiddenNote)
                let toggle = NSAttributedString(string: revealed.contains(comment.id) ? "Hide" : "Show",
                                                attributes: D.revealToggle)
                let labelWidth = min(label.size().width, max(0, textWidth - authorWidth - 6))
                label.draw(in: NSRect(x: left + authorWidth + 6, y: y + 1, width: labelWidth, height: D.authorHeight))
                authorWidth += 6 + labelWidth
                let size = toggle.size()
                if textWidth - authorWidth > size.width + 8 {
                    let rect = NSRect(x: left + authorWidth + 8, y: y + 1, width: size.width, height: D.authorHeight)
                    toggle.draw(in: rect)
                    revealRects.append((comment.id, rect.insetBy(dx: -4, dy: -2)))
                    authorWidth += 8 + size.width
                }
            }
            if !comment.date.isEmpty, textWidth - authorWidth > 20 {
                let date = NSAttributedString(string: comment.date, attributes: D.date)
                date.draw(in: NSRect(x: left + authorWidth + 6, y: y + 1, width: textWidth - authorWidth - 6,
                                     height: D.authorHeight))
            }
            y += D.authorHeight + D.bodyGap
            text.draw(with: NSRect(x: left, y: y, width: textWidth, height: bodyHeight),
                      options: [.usesLineFragmentOrigin, .usesFontLeading])
            y += bodyHeight
        }
    }
}

/// The "+" over a hovered line's gutter in a pull request's Files changed: a click opens a new comment box under the
/// line, ⇧-click makes a range with the open box.
final class DiffCommentButton: NSView {
    /// The row it sits on.
    var row = 0
    var onPress: ((Int, Bool) -> Void)?
    private var pressed = false

    override var isFlipped: Bool { true }

    override init(frame: NSRect) {
        super.init(frame: frame)
        toolTip = "Comment on this line (⇧-click another line for a range)"
        setAccessibilityElement(true)
        setAccessibilityRole(.button)
        setAccessibilityLabel("Comment on this line")
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) is not used") }

    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

    override func mouseDown(with event: NSEvent) {
        pressed = true
        needsDisplay = true
        // Acts on the press, as the line's own click would: the box shows in this event.
        onPress?(row, event.modifierFlags.contains(.shift))
        pressed = false
        needsDisplay = true
    }

    override func accessibilityPerformPress() -> Bool {
        onPress?(row, false)
        return true
    }

    override func resetCursorRects() {
        addCursorRect(bounds, cursor: .pointingHand)
    }

    override func draw(_ dirtyRect: NSRect) {
        NSColor(Palette.primaryFill).withAlphaComponent(pressed ? 0.7 : 1).setFill()
        // Every button of the app is a capsule (user, 2026-11-13): a circle on the square button.
        let radius = min(bounds.width, bounds.height) / 2
        NSBezierPath(roundedRect: bounds, xRadius: radius, yRadius: radius).fill()
        let symbol = NSImage(systemSymbolName: "plus", accessibilityDescription: nil)?
            .withSymbolConfiguration(NSImage.SymbolConfiguration(pointSize: bounds.height * 0.55, weight: .bold)
                .applying(NSImage.SymbolConfiguration(paletteColors: [.white])))
        if let symbol {
            let size = symbol.size
            symbol.draw(in: NSRect(x: (bounds.width - size.width) / 2, y: (bounds.height - size.height) / 2,
                                   width: size.width, height: size.height))
        }
    }
}

/// The new comment box's text: ⌘↩ posts, Esc cancels; a grey placeholder while empty.
final class DiffComposerTextView: NSTextView {
    var onPost: (() -> Void)?
    var onCancel: (() -> Void)?
    var placeholder = ""

    override func performKeyEquivalent(with event: NSEvent) -> Bool {
        // Only ⌘ of the modifier keys: keypad Enter (76) also carries `.numericPad` and `.function`.
        if window?.firstResponder === self,
           event.modifierFlags.intersection([.command, .shift, .option, .control]) == .command,
           [36, 76].contains(event.keyCode) {
            onPost?()
            return true
        }
        return super.performKeyEquivalent(with: event)
    }

    override func cancelOperation(_ sender: Any?) {
        onCancel?()
    }

    override func draw(_ dirtyRect: NSRect) {
        super.draw(dirtyRect)
        guard string.isEmpty, !placeholder.isEmpty else { return }
        let origin = textContainerOrigin
        let padding = textContainer?.lineFragmentPadding ?? 0
        NSAttributedString(string: placeholder, attributes: [
            .font: font ?? NSFont.systemFont(ofSize: 12), .foregroundColor: NSColor.placeholderTextColor,
        ]).draw(at: NSPoint(x: origin.x + padding, y: origin.y))
    }
}

/// A new inline comment's box under its line: in the thread rows' box, the line(s) it goes on (and why a range was
/// refused), the text, then Cancel and Comment (⌘↩). Native, like the thread rows.
final class DiffComposerCellView: NSView, NSTextViewDelegate {
    private typealias D = DiffThreadDrawing
    static let textHeight: CGFloat = 64
    static let height = 2 * D.margin + 2 * D.padding + D.headerHeight + 6 + textHeight + 8 + D.footerHeight

    private let title = NSTextField(labelWithString: "")
    private let message = NSTextField(labelWithString: "")
    private let scroll = NSScrollView()
    private let text = DiffComposerTextView()
    private let cancel = NSButton(title: "Cancel", target: nil, action: nil)
    private let comment = TintedCapsuleButton(title: "Comment", fill: NSColor(Palette.primaryFill))
    /// Start a review / Add review comment, where the pending review offers it (`DiffNewComments.review`).
    private let review = NSButton(title: "Start a review", target: nil, action: nil)
    /// Suggest a change, where the host renders suggestions and every line of the box is on the new side.
    private let suggest = NSButton(title: "Suggest a change", target: nil, action: nil)
    private var suggestion: String?
    private var busy = false
    private var onDraft: ((String) -> Void)?
    private var onCancel: (() -> Void)?
    private var onPost: ((String) -> Void)?
    private var onReview: ((String) -> Void)?

    override var isFlipped: Bool { true }
    override var isOpaque: Bool { false }

    override init(frame: NSRect) {
        super.init(frame: frame)
        title.font = .systemFont(ofSize: 11, weight: .semibold)
        title.textColor = .secondaryLabelColor
        title.lineBreakMode = .byTruncatingTail
        message.font = .systemFont(ofSize: 11)
        message.textColor = Palette.diffRemovedSign
        message.lineBreakMode = .byTruncatingTail
        text.isRichText = false
        text.allowsUndo = true
        text.font = .systemFont(ofSize: 12)
        text.textColor = Palette.diffText
        text.insertionPointColor = .white
        text.drawsBackground = false
        text.textContainerInset = NSSize(width: 2, height: 4)
        text.isAutomaticQuoteSubstitutionEnabled = false
        text.isAutomaticDashSubstitutionEnabled = false
        text.placeholder = "Leave a comment"
        text.delegate = self
        text.isVerticallyResizable = true
        text.autoresizingMask = [.width]
        text.textContainer?.widthTracksTextView = true
        text.onPost = { [weak self] in self?.post() }
        text.onCancel = { [weak self] in self?.onCancel?() }
        text.setAccessibilityLabel("Comment")
        scroll.documentView = text
        scroll.hasVerticalScroller = true
        scroll.autohidesScrollers = true
        scroll.drawsBackground = false
        scroll.borderType = .noBorder
        scroll.wantsLayer = true
        scroll.layer?.cornerRadius = 6
        scroll.layer?.backgroundColor = NSColor.white.withAlphaComponent(0.06).cgColor
        scroll.layer?.borderColor = NSColor.white.withAlphaComponent(0.12).cgColor
        scroll.layer?.borderWidth = 1
        cancel.bezelStyle = .push
        // Every button of the app is a capsule (user, 2026-11-13).
        if #available(macOS 26, *) { cancel.borderShape = .capsule }
        cancel.controlSize = .small
        cancel.font = .systemFont(ofSize: NSFont.systemFontSize(for: .small))
        cancel.target = self
        cancel.action = #selector(cancelPressed)
        comment.target = self
        comment.action = #selector(commentPressed)
        comment.toolTip = "Comment (⌘↩)"
        review.bezelStyle = .push
        if #available(macOS 26, *) { review.borderShape = .capsule }
        review.controlSize = .small
        review.font = .systemFont(ofSize: NSFont.systemFontSize(for: .small))
        review.target = self
        review.action = #selector(reviewPressed)
        review.isHidden = true
        suggest.bezelStyle = .push
        if #available(macOS 26, *) { suggest.borderShape = .capsule }
        suggest.controlSize = .small
        suggest.font = .systemFont(ofSize: NSFont.systemFontSize(for: .small))
        suggest.target = self
        suggest.action = #selector(suggestPressed)
        suggest.toolTip = "Insert a suggested change holding the lines"
        suggest.isHidden = true
        for view in [title, message, scroll, suggest, cancel, review, comment] { addSubview(view) }
        setAccessibilityElement(false)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) is not used") }

    func configure(_ composer: DiffInlineComposer, text draft: String, busy: Bool,
                   onDraft: @escaping (String) -> Void, onCancel: @escaping () -> Void,
                   onPost: @escaping (String) -> Void, commentTitle: String = "Comment",
                   review: (title: String, onPost: (String) -> Void)? = nil, suggestion: String? = nil) {
        self.onDraft = onDraft
        self.suggestion = suggestion
        suggest.isHidden = suggestion == nil
        self.onCancel = onCancel
        self.onPost = onPost
        onReview = review?.onPost
        comment.retitle(commentTitle)
        comment.toolTip = "\(commentTitle) (⌘↩)"
        review.map { self.review.title = $0.title }
        self.review.isHidden = review == nil
        title.stringValue = composer.title
        message.stringValue = composer.message ?? ""
        // The field keeps its own text (and caret) while it already holds the owner's.
        if text.string != draft { text.string = draft }
        setBusy(busy)
        needsLayout = true
        needsDisplay = true
    }

    func setBusy(_ busy: Bool) {
        self.busy = busy
        updateComment()
    }

    var hasFocus: Bool { window?.firstResponder === text }

    func focus() {
        window?.makeFirstResponder(text)
    }

    private func updateComment() {
        comment.isEnabled = !busy && !text.string.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        comment.alphaValue = comment.isEnabled ? 1 : 0.5
        review.isEnabled = comment.isEnabled
    }

    func textDidChange(_ notification: Notification) {
        onDraft?(text.string)
        updateComment()
        text.needsDisplay = true
    }

    @objc private func cancelPressed() {
        onCancel?()
    }

    @objc private func commentPressed() {
        post()
    }

    /// Inserts the suggestion block at the caret (replacing a selection) on lines of its own, as typed text: the draft
    /// and undo follow.
    @objc private func suggestPressed() {
        guard let suggestion, !busy else { return }
        let range = text.selectedRange()
        let before = (text.string as NSString).substring(to: min(range.location, (text.string as NSString).length))
        let block = (before.isEmpty || before.hasSuffix("\n") ? "" : "\n") + suggestion + "\n"
        window?.makeFirstResponder(text)
        text.insertText(block, replacementRange: range)
    }

    @objc private func reviewPressed() {
        guard comment.isEnabled else { return }
        onReview?(text.string.trimmingCharacters(in: .whitespacesAndNewlines))
    }

    private func post() {
        guard comment.isEnabled else { return }
        onPost?(text.string.trimmingCharacters(in: .whitespacesAndNewlines))
    }

    /// The card's visible width: the box stays in it when a long line makes the table wider.
    private var visibleWidth: CGFloat {
        let visible = enclosingScrollView?.contentView.bounds.width ?? 0
        return visible > 0 ? min(bounds.width, visible) : bounds.width
    }

    private var box: NSRect { D.box(width: visibleWidth, height: bounds.height) }

    override func setFrameSize(_ newSize: NSSize) {
        if newSize != frame.size {
            needsLayout = true
            needsDisplay = true
        }
        super.setFrameSize(newSize)
    }

    override func layout() {
        super.layout()
        let box = box
        let left = box.minX + D.padding, width = max(0, box.width - 2 * D.padding)
        // The title in full ("Comment on lines −3–+2"): the whole row without a message, else its cell's width,
        // rounded up (its `intrinsicContentSize` is a few points short: "Comment on lin…"), and the message the rest.
        let titleWidth = message.stringValue.isEmpty
            ? width : min(ceil(title.cell?.cellSize.width ?? title.intrinsicContentSize.width), width)
        title.frame = NSRect(x: left, y: box.minY + D.padding + (D.headerHeight - 14) / 2, width: titleWidth,
                             height: 14)
        message.frame = NSRect(x: left + titleWidth + 8, y: title.frame.minY, width: max(0, width - titleWidth - 8),
                               height: 14)
        scroll.frame = NSRect(x: left, y: box.minY + D.padding + D.headerHeight + 6, width: width,
                              height: Self.textHeight)
        text.minSize = NSSize(width: 0, height: Self.textHeight)
        text.maxSize = NSSize(width: CGFloat.greatestFiniteMagnitude, height: CGFloat.greatestFiniteMagnitude)
        text.frame.size.width = scroll.contentSize.width
        text.sizeToFit()
        let footerY = scroll.frame.maxY + 8
        let commentSize = comment.intrinsicContentSize
        comment.frame = NSRect(x: box.maxX - D.padding - commentSize.width,
                               y: footerY + (D.footerHeight - commentSize.height) / 2,
                               width: commentSize.width, height: commentSize.height)
        let reviewSize = review.isHidden ? .zero : review.fittingSize
        review.frame = NSRect(x: comment.frame.minX - 8 - reviewSize.width,
                              y: footerY + (D.footerHeight - reviewSize.height) / 2,
                              width: reviewSize.width, height: reviewSize.height)
        let suggestSize = suggest.isHidden ? .zero : suggest.fittingSize
        suggest.frame = NSRect(x: left, y: footerY + (D.footerHeight - suggestSize.height) / 2,
                               width: suggestSize.width, height: suggestSize.height)
        let cancelSize = cancel.fittingSize
        let cancelRight = review.isHidden ? comment.frame.minX : review.frame.minX
        cancel.frame = NSRect(x: cancelRight - 8 - cancelSize.width,
                              y: footerY + (D.footerHeight - cancelSize.height) / 2,
                              width: cancelSize.width, height: cancelSize.height)
    }

    override func mouseDown(with event: NSEvent) {
        // A click in the box but off its controls: nothing (it is not a line the table selects).
    }

    override func draw(_ dirtyRect: NSRect) {
        let shape = NSBezierPath(roundedRect: box.insetBy(dx: 0.5, dy: 0.5), xRadius: 8, yRadius: 8)
        D.boxFill.setFill()
        shape.fill()
        D.boxEdge.setStroke()
        shape.lineWidth = 1
        shape.stroke()
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

    /// Shows `title` (white, small), when it is another one.
    func retitle(_ title: String) {
        guard attributedTitle.string != title else { return }
        attributedTitle = NSAttributedString(string: title, attributes: [
            .font: NSFont.systemFont(ofSize: NSFont.systemFontSize(for: .small)),
            .foregroundColor: NSColor.white,
        ])
        invalidateIntrinsicContentSize()
        superview?.needsLayout = true
    }

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
