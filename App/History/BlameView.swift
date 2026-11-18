// A file's blame in panel2, in place of the graph: one card whose header is the blame's row (a "Blame" badge,
// "folder / name", the revision or "Working Tree", wrap and close), then the file's lines in a table. Each line has a
// gutter (the short sha, message, author and date of the commit that last changed it, on the first line of each run of
// lines from that commit), its number and its text in syntax colors. A click on a gutter selects that commit in
// panel3 and keeps the blame open.
//
// The blame loads off the main actor (`RepoSession.selectTool`); its rows (with their tokens) are built off the main
// actor too, then the table only draws the rows on screen. Until both are done the card holds skeleton rows.
import AppKit
import HistqCore
import SwiftUI

/// Panel2 while a file's blame is open: the card and its header at once, then the lines (skeletons until loaded).
struct BlameView: View {
    let session: RepoSession
    let path: String
    /// The blamed commit-ish; nil for the working tree.
    let rev: String?
    @Environment(WindowModel.self) private var model
    @Environment(\.cardExtraPadding) private var extraPadding
    @Environment(\.cardExtraVerticalPadding) private var extraVerticalPadding
    @AppStorage(PrefKey.dateFormat.rawValue, store: Preferences.defaults) private var dateFormat = "MM/dd/yy @ HH:mm"
    @AppStorage(PrefKey.blameWrapLines.rawValue, store: Preferences.defaults) private var wrapLines = false
    /// The rows of the last loaded blame, for the tool select (`toolToken`) they were built for.
    @State private var built: BlameRows?

    var body: some View {
        let groups: [BlameGroup]? = if case .loaded(.blame(let groups)) = session.toolState { groups } else { nil }
        // Set once the blame is in: its rows are built then, off the main actor.
        let readyToken = groups == nil ? nil : session.toolToken
        SectionCard(nil, contentPadding: 0) {
            BlameHeader(session: session, path: path, rev: rev, wrapLines: $wrapLines)
            Group {
                if case .failed(let message) = session.toolState {
                    notice(FileNotice(systemImage: "exclamationmark.triangle", message: message))
                        .onAppear { UITiming.content("\(session.toolDetail) failed") }
                } else if case .loaded(.binary) = session.toolState {
                    notice(FileNotice(systemImage: "doc.zipper",
                                      message: "Histq does not show the contents of binary files."))
                        .onAppear { UITiming.content(session.toolDetail) }
                } else if case .loaded(.tooLarge(let bytes)) = session.toolState {
                    notice(FileNotice(
                        systemImage: "doc.badge.clock",
                        message: "This file is \(ByteCountFormatter.string(fromByteCount: Int64(bytes), countStyle: .file)), "
                            + "over the \(ByteCountFormatter.string(fromByteCount: Int64(RepoSession.fileSizeLimit), countStyle: .file)) "
                            + "Histq blames."
                    ))
                    .onAppear { UITiming.content(session.toolDetail) }
                } else if let built, readyToken == built.token {
                    BlameLines(session: session, blame: built, dateFormat: dateFormat, wrapLines: wrapLines)
                        .onAppear { UITiming.content(session.toolDetail) }
                } else {
                    PlaceholderCard(
                        token: session.toolToken, detail: session.toolDetail,
                        isCurrent: { [model, session, path, rev] in
                            model.selectedSession === session && session.openTool == .blame(path: path, rev: rev)
                        }
                    ) {
                        BlamePlaceholder()
                    }
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
        }
        .task(id: readyToken) {
            guard let readyToken, let groups else { return }
            let rows = await BlameRowBuilder.build(groups, path: path, token: readyToken)
            guard !Task.isCancelled else { return }
            built = rows
        }
    }

    /// A notice in place of the lines, at the card's insets.
    private func notice(_ notice: some View) -> some View {
        notice
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.horizontal, SettingsMetrics.cardPadding + extraPadding)
            .padding(.bottom, SettingsMetrics.cardPadding + extraVerticalPadding)
    }
}

/// The blame card's header, at the open file's row's insets and height (`DiffFileHeader`): the "Blame" badge,
/// "folder / name" (the folder secondary, truncating from its head), the blamed revision, the wrap switch and close
/// (Esc, back to the graph).
private struct BlameHeader: View {
    let session: RepoSession
    let path: String
    let rev: String?
    @Binding var wrapLines: Bool
    @Environment(\.cardExtraPadding) private var extraPadding
    @Environment(\.cardExtraVerticalPadding) private var extraVerticalPadding

    var body: some View {
        let name = (path as NSString).lastPathComponent
        let folder = (path as NSString).deletingLastPathComponent
        HStack(spacing: 12) {
            HStack(spacing: 8) {
                Text("Blame")
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(Color.accentColor)
                    .padding(.horizontal, 7)
                    .padding(.vertical, 2)
                    .background(Capsule().fill(Color.accentColor.opacity(0.18)))
                    .fixedSize()
                HStack(spacing: 0) {
                    if !folder.isEmpty {
                        // Every "/" gets one space on each side, as the one before the name (`DiffFileHeader`).
                        Text(folder.replacing("/", with: " / ") + " /")
                            .foregroundStyle(.secondary)
                            .lineLimit(1)
                            .truncationMode(.head)
                    }
                    Text(folder.isEmpty ? name : " " + name)
                        .lineLimit(1)
                        .layoutPriority(1)
                }
                .help(path)
                .accessibilityElement(children: .ignore)
                .accessibilityLabel("Blame of \(path)")
            }
            Spacer(minLength: 0)
            Group {
                if let rev {
                    Text(GitOperations.isObjectID(rev) ? String(rev.prefix(7)) : rev)
                        .font(.callout.monospaced())
                        .help(rev)
                } else {
                    Text("Working Tree")
                }
            }
            .foregroundStyle(.secondary)
            .lineLimit(1)
            .truncationMode(.middle)
            Button {
                wrapLines.toggle()
            } label: {
                IconImage("lucide-wrap-text", size: 16)
                    .foregroundStyle(wrapLines ? AnyShapeStyle(Color.accentColor) : AnyShapeStyle(.secondary))
                    .frame(width: 22, height: 22)
            }
            .buttonStyle(RowIconButtonStyle())
            .help(wrapLines ? "Don't Wrap Lines" : "Wrap Lines")
            .accessibilityLabel("Wrap lines")
            .accessibilityValue(wrapLines ? "On" : "Off")
            Button {
                session.closeFile()
            } label: {
                Image(systemName: "xmark")
                    .font(.system(size: 14, weight: .semibold))
                    .foregroundStyle(.secondary)
                    .frame(width: 22, height: 22)
            }
            .buttonStyle(RowIconButtonStyle())
            .keyboardShortcut(.cancelAction)
            .help("Close the Blame (Esc)")
            .accessibilityLabel("Close the blame")
        }
        .padding(.horizontal, SettingsMetrics.cardPadding + extraPadding)
        .frame(height: 40)
        .padding(.top, extraVerticalPadding * 2 / 3)
    }
}

/// The loaded lines: the table fills the card and scrolls.
private struct BlameLines: View {
    let session: RepoSession
    let blame: BlameRows
    let dateFormat: String
    let wrapLines: Bool

    var body: some View {
        let selectedHash: String? = if case .commit(let hash) = session.selection { hash } else { nil }
        if blame.rows.isEmpty {
            Text("Empty file.")
                .foregroundStyle(.secondary)
                .padding(.horizontal, 12)
                .padding(.bottom, 10)
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        } else {
            BlameTable(blame: blame, selectedHash: selectedHash, dateFormat: dateFormat, wrapLines: wrapLines,
                       onSelect: { [session] hash in session.selectKeepingTool(hash) },
                       onClose: { [session] in session.closeFile() })
                .frame(maxHeight: .infinity)
        }
    }
}

/// The blame's skeleton under its header: rows of gutter bars, a line number and a text bar.
private struct BlamePlaceholder: View {
    private static let widths: [CGFloat] = [0.55, 0.7, 0.4, 0.62, 0.5, 0.75, 0.35, 0.6, 0.45, 0.66, 0.52, 0.3]

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            ForEach(Self.widths.indices, id: \.self) { index in
                HStack(spacing: 10) {
                    SkeletonLine(width: 44, height: 9)
                    SkeletonLine(width: 180, height: 9)
                    SkeletonLine(width: 90, height: 9)
                    SkeletonLine(width: 84, height: 9)
                    SkeletonLine(width: 20, height: 9)
                    SkeletonLine(fraction: Self.widths[index], height: 10)
                }
                .padding(.horizontal, 10)
                .frame(height: DiffLayout.lineHeight)
            }
        }
        .padding(.bottom, 8)
        // The loaded lines fill the card: so do their skeletons.
        .frame(maxHeight: .infinity, alignment: .top)
    }
}

// MARK: - Rows

/// One line of the blame, ready to draw.
struct BlameRow: Sendable {
    /// Its run of lines (`BlameRows.groups`).
    let group: Int
    /// The first line of its run: the gutter shows the commit here.
    let isFirst: Bool
    /// Its number in the blamed file.
    let line: Int
    let text: String
    let tokens: [SyntaxToken]
    /// Its width in characters (a tab counts as `DiffLayout.tabWidth`): a line that fits needs no measuring to wrap.
    let columns: Int
}

/// A loaded blame's rows, for the tool select `token` they were built for.
struct BlameRows: Sendable {
    let token: Int
    let groups: [BlameGroup]
    let rows: [BlameRow]
    /// The longest line in characters (a tab counts as `DiffLayout.tabWidth`), and the largest line number.
    let longest: Int
    let largestLine: Int
}

/// Builds a blame's rows, off the main actor.
enum BlameRowBuilder {
    /// The lines in file order, scanned with one state from the first, so a line inside a block comment is colored
    /// right.
    @concurrent
    static func build(_ groups: [BlameGroup], path: String, token: Int) async -> BlameRows {
        let language = LanguageTable.language(forPath: path)
        var state = ScanState()
        var rows: [BlameRow] = []
        rows.reserveCapacity(groups.reduce(0) { $0 + $1.lines.count })
        var longest = 0
        var largest = 0
        for (index, group) in groups.enumerated() {
            for (offset, line) in group.lines.enumerated() {
                let text = DiffRowBuilder.display(line.text)
                let tokens = SyntaxScanner.scan(line: text, state: &state, language: language)
                let tabs = text.utf16.count { $0 == 0x09 }
                let columns = text.utf16.count + tabs * (DiffLayout.tabWidth - 1)
                rows.append(BlameRow(group: index, isFirst: offset == 0, line: line.finalLine, text: text,
                                     tokens: tokens, columns: columns))
                longest = max(longest, columns)
                largest = max(largest, line.finalLine)
            }
        }
        return BlameRows(token: token, groups: groups, rows: rows, longest: longest, largestLine: largest)
    }
}

// MARK: - Table

/// The blame's table. `blame.token` and `dateFormat` say which rows it shows; `selectedHash` marks the gutter of that
/// commit's lines; `wrapLines` wraps long lines at the card's width instead of scrolling sideways. A click on a
/// committed line's gutter calls `onSelect` with its commit; Esc calls `onClose`.
private struct BlameTable: NSViewRepresentable {
    let blame: BlameRows
    let selectedHash: String?
    let dateFormat: String
    let wrapLines: Bool
    let onSelect: @MainActor (String) -> Void
    let onClose: @MainActor () -> Void

    func makeCoordinator() -> BlameTableController { BlameTableController() }

    func makeNSView(context: Context) -> NSScrollView {
        let table = BlameTableView()
        table.style = .plain
        table.backgroundColor = .clear
        table.gridStyleMask = []
        table.intercellSpacing = .zero
        table.usesAutomaticRowHeights = false
        table.rowHeight = DiffLayout.lineHeight
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
        // Unless lines wrap, a long line scrolls sideways.
        scroll.hasHorizontalScroller = true
        scroll.autohidesScrollers = true

        context.coordinator.attach(table)
        return scroll
    }

    func updateNSView(_ scroll: NSScrollView, context: Context) {
        context.coordinator.update(self)
    }
}

/// Column positions of the blame's rows: the gutter (sha, message, author, date), the line number, then the text. The
/// content width fits the longest line, so the table scrolls sideways unless lines wrap.
private struct BlameLayout {
    @MainActor static let shaFont = NSFont.monospacedSystemFont(ofSize: 11, weight: .regular)
    @MainActor static let authorFont = NSFont.systemFont(ofSize: 11)
    static let padding: CGFloat = 8
    static let messageWidth: CGFloat = 220
    static let authorWidth: CGFloat = 110
    /// Right of a wrapped line's text.
    static let trailingPadding: CGFloat = 12

    let shaWidth: CGFloat
    let dateWidth: CGFloat
    let numberWidth: CGFloat
    let contentWidth: CGFloat

    var messageX: CGFloat { Self.padding + shaWidth + Self.padding }
    var authorX: CGFloat { messageX + Self.messageWidth + Self.padding }
    var dateX: CGFloat { authorX + Self.authorWidth + Self.padding }
    var gutterWidth: CGFloat { dateX + dateWidth + Self.padding }
    var textX: CGFloat { gutterWidth + numberWidth + Self.padding }

    /// The text's width when lines wrap in a column `column` wide (a few characters at least).
    @MainActor func wrapWidth(column: CGFloat) -> CGFloat {
        max(DiffLayout.charWidth * 8, column - textX - Self.trailingPadding)
    }

    @MainActor init(blame: BlameRows, formatter: DateFormatter) {
        shaWidth = ("0000000" as NSString).size(withAttributes: [.font: Self.shaFont]).width
        // The widest date of the format: month names and unpadded fields change its width.
        let calendar = Calendar(identifier: .gregorian)
        dateWidth = (1...12).compactMap { calendar.date(from: DateComponents(year: 2028, month: $0, day: 28, hour: 22)) }
            .map { (formatter.string(from: $0) as NSString).size(withAttributes: [.font: DiffLayout.numberFont]).width }
            .max()?.rounded(.up) ?? 0
        let digits = max(3, String(blame.largestLine).count)
        numberWidth = CGFloat(digits) * DiffLayout.charWidth + 14
        contentWidth = Self.padding + shaWidth + Self.padding + Self.messageWidth + Self.padding + Self.authorWidth
            + Self.padding + dateWidth + Self.padding + numberWidth + Self.padding
            + CGFloat(blame.longest) * DiffLayout.charWidth + 24
    }

    init() {
        shaWidth = 0
        dateWidth = 0
        numberWidth = 40
        contentWidth = 0
    }
}

/// The blame table: its one column is as wide as the longest line or the card, whichever is wider (as wide as the card
/// when lines wrap). Esc asks to go back; a click on a gutter selects its commit (no row selection).
private final class BlameTableView: NSTableView {
    var contentWidth: CGFloat = 0 {
        didSet { if contentWidth != oldValue { tile() } }
    }
    /// Lines wrap at the card's width: a new width measures the rows' heights again.
    var wrapLines = false {
        didSet { if wrapLines != oldValue { tile() } }
    }
    /// The column width the rows' heights were last measured at, while lines wrap.
    private var measuredWidth: CGFloat = 0
    var gutterWidth: CGFloat = 0 {
        didSet { if gutterWidth != oldValue { window?.invalidateCursorRects(for: self) } }
    }
    weak var controller: BlameTableController?
    /// Takes the keyboard once, when it first shows, so Esc works without a click (`DiffTableView`'s way).
    private var tookFocus = false

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        guard let window, !tookFocus else { return }
        tookFocus = true
        window.makeFirstResponder(self)
    }

    /// A new card width fits the column again (and measures wrapped rows again): the table is not told otherwise.
    override func viewDidMoveToSuperview() {
        super.viewDidMoveToSuperview()
        NotificationCenter.default.removeObserver(self, name: NSView.frameDidChangeNotification, object: nil)
        guard let clip = superview as? NSClipView else { return }
        clip.postsFrameChangedNotifications = true
        NotificationCenter.default.addObserver(self, selector: #selector(clipResized),
                                               name: NSView.frameDidChangeNotification, object: clip)
    }

    @objc private func clipResized(_ note: Notification) { tile() }

    override func tile() {
        super.tile()
        guard let clip = enclosingScrollView?.contentView, let column = tableColumns.first else { return }
        let width = wrapLines ? clip.bounds.width : max(contentWidth, clip.bounds.width)
        if abs(column.width - width) > 0.5 { column.width = width }
        if wrapLines, abs(measuredWidth - width) > 0.5, numberOfRows > 0 {
            measuredWidth = width
            noteHeightOfRows(withIndexesChanged: IndexSet(integersIn: 0..<numberOfRows))
        }
    }

    override func resetCursorRects() {
        super.resetCursorRects()
        addCursorRect(NSRect(x: 0, y: 0, width: gutterWidth, height: bounds.height), cursor: .pointingHand)
    }

    override func mouseDown(with event: NSEvent) {
        let point = convert(event.locationInWindow, from: nil)
        if point.x < gutterWidth {
            controller?.clickGutter(row: row(at: point))
        } else {
            super.mouseDown(with: event)
        }
    }

    override func keyDown(with event: NSEvent) {
        // Escape: back to the graph.
        if event.keyCode == 53 {
            controller?.close()
        } else {
            super.keyDown(with: event)
        }
    }
}

/// The table's data source and delegate: it keeps the rows it shows and reloads only when they or the marked commit
/// change.
@MainActor
private final class BlameTableController: NSObject, NSTableViewDataSource, NSTableViewDelegate {
    private weak var table: BlameTableView?
    private var view: BlameTable?
    private var blame: BlameRows?
    private var layout = BlameLayout()
    private let formatter = DateFormatter()

    private struct Shown: Equatable {
        let token: Int
        let dateFormat: String
        let selectedHash: String?
        let wrapLines: Bool
    }

    private var shown: Shown?

    private static let lineID = NSUserInterfaceItemIdentifier("blameLine")

    override init() {
        formatter.locale = Locale(identifier: Locale.current.identifier)
        super.init()
    }

    func attach(_ table: BlameTableView) {
        self.table = table
        table.controller = self
        table.dataSource = self
        table.delegate = self
    }

    func update(_ view: BlameTable) {
        self.view = view
        guard let table else { return }
        let key = Shown(token: view.blame.token, dateFormat: view.dateFormat, selectedHash: view.selectedHash,
                        wrapLines: view.wrapLines)
        guard key != shown else { return }
        if shown?.token != key.token || shown?.dateFormat != key.dateFormat {
            blame = view.blame
            formatter.dateFormat = view.dateFormat
            layout = BlameLayout(blame: view.blame, formatter: formatter)
            table.contentWidth = layout.contentWidth
            table.gutterWidth = layout.gutterWidth
        }
        shown = key
        table.wrapLines = view.wrapLines
        // Only the rows on screen are made again, the scroll offset stays.
        table.reloadData()
    }

    func close() {
        view?.onClose()
    }

    /// A committed line's gutter selects its commit; a "Not Committed Yet" line's does nothing.
    func clickGutter(row: Int) {
        guard let blame, blame.rows.indices.contains(row) else { return }
        let group = blame.groups[blame.rows[row].group]
        if group.isCommitted { view?.onSelect(group.hash) }
    }

    // MARK: Data

    func numberOfRows(in tableView: NSTableView) -> Int { blame?.rows.count ?? 0 }

    func tableView(_ tableView: NSTableView, viewFor tableColumn: NSTableColumn?, row: Int) -> NSView? {
        guard let blame, blame.rows.indices.contains(row) else { return nil }
        let data = blame.rows[row]
        let group = blame.groups[data.group]
        let cell = tableView.makeView(withIdentifier: Self.lineID, owner: nil) as? BlameLineCellView ?? {
            let cell = BlameLineCellView()
            cell.identifier = Self.lineID
            return cell
        }()
        cell.row = data
        cell.group = group
        cell.date = data.isFirst && group.isCommitted ? formatter.string(from: group.authorDate) : ""
        cell.isSeparated = data.isFirst && row > 0
        cell.isMarked = group.isCommitted && group.hash == shown?.selectedHash
        cell.layout = layout
        cell.wrapLines = shown?.wrapLines ?? false
        cell.toolTip = group.isCommitted
            ? "\(group.hash.prefix(7)) \(group.summary)\n\(group.authorName), \(formatter.string(from: group.authorDate))"
            : "Not Committed Yet"
        cell.needsDisplay = true
        return cell
    }

    /// One line's height, or as many as the line takes wrapped at the column's width; a line that fits is not
    /// measured.
    func tableView(_ tableView: NSTableView, heightOfRow row: Int) -> CGFloat {
        guard shown?.wrapLines == true, let blame, blame.rows.indices.contains(row),
              let width = tableView.tableColumns.first?.width else { return DiffLayout.lineHeight }
        let data = blame.rows[row]
        let textWidth = layout.wrapWidth(column: width)
        if CGFloat(data.columns) * DiffLayout.charWidth <= textWidth { return DiffLayout.lineHeight }
        let size = NSAttributedString(string: data.text, attributes: BlameLineCellView.wrappedText)
            .boundingRect(with: NSSize(width: textWidth, height: .greatestFiniteMagnitude),
                          options: [.usesLineFragmentOrigin])
        return max(DiffLayout.lineHeight, size.height.rounded(.up))
    }

    /// No row selection: a click either selects a commit (gutter) or does nothing.
    func tableView(_ tableView: NSTableView, selectionIndexesForProposedSelection proposed: IndexSet) -> IndexSet {
        IndexSet()
    }
}

/// A line: its gutter (the commit on the first line of its run, a tinted band for lines not committed yet, a mark for
/// the selected commit's lines), its number, then its text in syntax colors.
private final class BlameLineCellView: NSView {
    var row: BlameRow? {
        didSet { setAccessibilityLabel(row?.text) }
    }
    var group: BlameGroup?
    /// The commit's date, on the first line of a committed run; empty otherwise.
    var date = ""
    /// The first line of a run after another: a hairline above it.
    var isSeparated = false
    /// A line of the selected commit.
    var isMarked = false
    var layout = BlameLayout()
    /// The text wraps at the cell's width.
    var wrapLines = false

    /// A wrapped line's text: each line `DiffLayout.lineHeight` tall, the glyphs centered in it as an unwrapped line's
    /// (`BlameTableController` measures the rows' heights with it too).
    @MainActor static let wrappedText: [NSAttributedString.Key: Any] = {
        let style = NSMutableParagraphStyle()
        style.tabStops = []
        style.defaultTabInterval = CGFloat(DiffLayout.tabWidth) * DiffLayout.charWidth
        style.lineBreakMode = .byWordWrapping
        style.minimumLineHeight = DiffLayout.lineHeight
        style.maximumLineHeight = DiffLayout.lineHeight
        let natural = NSLayoutManager().defaultLineHeight(for: DiffLayout.font)
        return [.font: DiffLayout.font, .foregroundColor: Palette.diffText, .paragraphStyle: style,
                .baselineOffset: (DiffLayout.lineHeight - natural) / 2]
    }()

    override var isFlipped: Bool { true }
    override var isOpaque: Bool { false }

    override init(frame: NSRect) {
        super.init(frame: frame)
        setAccessibilityElement(true)
        setAccessibilityRole(.staticText)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) is not used") }

    @MainActor
    private enum Style {
        static let paragraph: NSParagraphStyle = {
            let style = NSMutableParagraphStyle()
            style.tabStops = []
            style.defaultTabInterval = CGFloat(DiffLayout.tabWidth) * DiffLayout.charWidth
            style.lineBreakMode = .byClipping
            return style
        }()
        static let text: [NSAttributedString.Key: Any] = [
            .font: DiffLayout.font, .foregroundColor: Palette.diffText, .paragraphStyle: paragraph,
        ]
        static let number: [NSAttributedString.Key: Any] = {
            let style = NSMutableParagraphStyle()
            style.alignment = .right
            return [.font: DiffLayout.numberFont, .foregroundColor: Palette.diffLineNumber, .paragraphStyle: style]
        }()
        static let sha: [NSAttributedString.Key: Any] = [
            .font: BlameLayout.shaFont, .foregroundColor: Palette.diffLineNumber,
        ]
        static let message: [NSAttributedString.Key: Any] = {
            let style = NSMutableParagraphStyle()
            style.lineBreakMode = .byTruncatingTail
            return [.font: BlameLayout.authorFont, .foregroundColor: NSColor.labelColor, .paragraphStyle: style]
        }()
        static let author: [NSAttributedString.Key: Any] = {
            let style = NSMutableParagraphStyle()
            style.lineBreakMode = .byTruncatingTail
            return [.font: BlameLayout.authorFont, .foregroundColor: NSColor.secondaryLabelColor,
                    .paragraphStyle: style]
        }()
        static let date: [NSAttributedString.Key: Any] = [
            .font: DiffLayout.numberFont, .foregroundColor: Palette.diffLineNumber,
        ]
        static let notCommitted: [NSAttributedString.Key: Any] = [
            .font: BlameLayout.authorFont, .foregroundColor: Palette.conflictA,
        ]
        static let separator = NSColor.white.withAlphaComponent(0.08)

        /// `DiffLineCellView`'s token colors.
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

    override func draw(_ dirtyRect: NSRect) {
        guard let row, let group else { return }
        let height = bounds.height
        // The gutter and the number sit on the first line of a wrapped row.
        let lineHeight = DiffLayout.lineHeight
        let gutter = NSRect(x: 0, y: 0, width: layout.gutterWidth, height: height)
        if !group.isCommitted {
            Palette.conflictAFill.setFill()
            gutter.fill(using: .sourceOver)
        } else if isMarked {
            Palette.graphSelection.setFill()
            gutter.fill(using: .sourceOver)
        }
        if isSeparated {
            Style.separator.setFill()
            NSRect(x: 0, y: 0, width: bounds.width, height: 1).fill(using: .sourceOver)
        }
        let smallY = (lineHeight - DiffLayout.numberFont.boundingRectForFont.height) / 2
        if row.isFirst {
            if group.isCommitted {
                NSString(string: String(group.hash.prefix(7)))
                    .draw(at: NSPoint(x: BlameLayout.padding, y: smallY), withAttributes: Style.sha)
                // Truncated with "…": the row's tooltip has the whole message.
                NSString(string: group.summary).draw(
                    in: NSRect(x: layout.messageX, y: smallY, width: BlameLayout.messageWidth, height: lineHeight),
                    withAttributes: Style.message)
                NSString(string: group.authorName).draw(
                    in: NSRect(x: layout.authorX, y: smallY, width: BlameLayout.authorWidth, height: lineHeight),
                    withAttributes: Style.author)
                NSString(string: date).draw(
                    in: NSRect(x: layout.dateX, y: smallY, width: layout.dateWidth, height: lineHeight),
                    withAttributes: Style.date)
            } else {
                NSString(string: "Not Committed Yet")
                    .draw(at: NSPoint(x: BlameLayout.padding, y: smallY), withAttributes: Style.notCommitted)
            }
        }
        NSString(string: "\(row.line)").draw(
            in: NSRect(x: layout.gutterWidth, y: smallY, width: layout.numberWidth - 8, height: lineHeight),
            withAttributes: Style.number)

        let text = NSMutableAttributedString(string: row.text, attributes: wrapLines ? Self.wrappedText : Style.text)
        let length = text.length
        for token in row.tokens where NSMaxRange(token.range) <= length {
            text.addAttribute(.foregroundColor, value: Style.color(token.kind), range: token.range)
        }
        if wrapLines {
            text.draw(with: NSRect(x: layout.textX, y: 0, width: layout.wrapWidth(column: bounds.width), height: height),
                      options: [.usesLineFragmentOrigin])
        } else {
            let textY = (lineHeight - (DiffLayout.font.ascender - DiffLayout.font.descender)) / 2
            text.draw(at: NSPoint(x: layout.textX, y: textY))
        }
    }
}
