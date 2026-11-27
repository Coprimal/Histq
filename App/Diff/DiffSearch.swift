// The open file's search (⌘F, the controls card's magnifying glass): a repo tab's `DiffSearch` (the query, its matches
// off the main actor, the current match) and the bar above the diff's cards. It searches the lines the diff shows in
// its mode (Diff, Split or Full file), across all its cards in order, case-insensitively; each table marks its card's
// matches and scrolls to the current one.
import AppKit
import SwiftUI

/// One match: in the card of `side`, table row `row` (`DiffSection.tableRows`), a part (UTF-16) of a unified row's line
/// or of a split row's old or new line. A split context line counts once, on `.old`; both halves mark it.
struct DiffSearchMatch: Sendable, Equatable {
    let side: DiffSide
    let row: Int
    let column: DiffTextColumn
    let range: NSRange
}

/// The search as one table shows it: its card's matches, the index of the current one among them, and the last move to
/// a match (`reveal`). `token` is new with each search result, so the table compares it, never the matches; `loadID`
/// and `mode` are the rows the matches were found in.
struct DiffTableSearch {
    let token: Int
    let loadID: Int
    let mode: DiffMode
    let matches: [DiffSearchMatch]
    let current: Int?
    let reveal: Int
}

/// A repo tab's diff search. Each query change searches the open file's rows off the main actor and drops the result
/// of the search before it; a new load or mode of the file searches again. A typed query goes to its first match;
/// a new load keeps the current match's place while there are as many matches.
@Observable
@MainActor
final class DiffSearch: FindBarModel {
    /// The bar shows.
    private(set) var isOpen = false
    var query = "" {
        didSet {
            guard query != oldValue else { return }
            search(jump: true)
        }
    }

    /// The matches, cards in order, top row first, for `searched`'s rows.
    private(set) var matches: [DiffSearchMatch] = []
    /// `matches`' index of the current match; nil until the search goes to one.
    private(set) var current: Int?
    /// `matches` belong to the current query.
    private(set) var isFresh = true
    /// More matches than `limit`: only the first ones are kept.
    private(set) var isCapped = false
    /// New with each open (⌘F, also while open): the bar focuses its field and selects its text.
    private(set) var focusToken = 0
    /// New with each move to a match: its table scrolls it into view.
    private(set) var revealToken = 0
    /// New with each result.
    private(set) var token = 0

    /// The tab's session, for its open file's diff and mode, and its table (the keyboard's place when the bar closes).
    @ObservationIgnored weak var session: RepoSession?
    @ObservationIgnored weak var fieldAnchor: FieldAnchor.Box?

    /// The rows a search reads: a file's load in a mode.
    private struct Key: Equatable {
        let loadID: Int
        let mode: DiffMode
    }

    /// The most matches kept: a one-letter query in a big file finds hundreds of thousands.
    private nonisolated static let limit = 10_000

    /// Observed: the tables' `tableSearch` reads it first.
    private var searched: Key?
    /// `matches` by card, and each card's first index in `matches`.
    @ObservationIgnored private var bySide: [DiffSide: [DiffSearchMatch]] = [:]
    @ObservationIgnored private var offsets: [DiffSide: Int] = [:]
    @ObservationIgnored private var task: Task<Void, Never>?
    /// New for each search; a result of an older one is dropped.
    @ObservationIgnored private var generation = 0

    var hasMatches: Bool { !matches.isEmpty }
    var isShown: Bool { session?.isShown != false }
    var fieldTitle: String { "Find in file" }
    var fieldPrompt: String { "Find in file" }

    /// "3 of 12", "No results", or nothing without a query.
    var summary: String {
        guard !query.isEmpty else { return "" }
        guard !matches.isEmpty else { return isFresh ? "No results" : "" }
        return "\(current.map { $0 + 1 } ?? 0) of \(matches.count)\(isCapped ? "+" : "")"
    }

    /// Opens the bar, or while open focuses it again. A closed bar opens empty: its last query stayed while it slid
    /// away (`close`).
    func open() {
        if !isOpen { query = "" }
        isOpen = true
        focusToken &+= 1
        contentDidChange()
    }

    /// Esc, the bar's close: closes the bar (the tables stop marking); the diff's table gets the keyboard back.
    func close() { close(focusesTable: true) }

    /// Closes the bar; `focusesTable` false when the file closes too (its table goes). The query stays, so the bar's
    /// text does not change while it slides away; the next `open` clears it.
    func close(focusesTable: Bool) {
        guard isOpen else { return }
        isOpen = false
        guard focusesTable, let table = session?.diffTable, let window = table.window else { return }
        // The field editor resigns on its own turn: after it.
        DispatchQueue.main.async { [weak table] in
            guard let table, table.window === window else { return }
            window.makeFirstResponder(table)
        }
    }

    /// The open file's rows changed (a new load, another mode): searches them again while a query is typed.
    func contentDidChange() {
        guard isOpen, !query.isEmpty, shownKey != searched else { return }
        search(jump: false)
    }

    /// Enter, the bar's down arrow: the next match, from the last to the first.
    func next() {
        guard isFresh, !matches.isEmpty else { return }
        go(to: current.map { ($0 + 1) % matches.count } ?? 0)
    }

    /// Shift-Enter, the bar's up arrow: the previous match, from the first to the last.
    func previous() {
        guard isFresh, !matches.isEmpty else { return }
        go(to: current.map { ($0 - 1 + matches.count) % matches.count } ?? matches.count - 1)
    }

    /// What the table of `side`'s card marks; nil while the bar is closed or has no result.
    func tableSearch(for side: DiffSide) -> DiffTableSearch? {
        guard isOpen, let searched else { return nil }
        let mine = bySide[side] ?? []
        let offset = offsets[side] ?? 0
        let local = current.flatMap { $0 >= offset && $0 < offset + mine.count ? $0 - offset : nil }
        return DiffTableSearch(token: token, loadID: searched.loadID, mode: searched.mode, matches: mine,
                               current: local, reveal: revealToken)
    }

    // MARK: Searching

    /// The open file's loaded rows in the session's mode; nil without lines.
    private var shownKey: Key? {
        guard let session, let detail = session.fileDiff.value, case .sections = detail.content else { return nil }
        return Key(loadID: detail.loadID, mode: session.diffMode)
    }

    /// Searches the open file's rows for `query` off the main actor. `jump`: a typed query, which goes to its first
    /// match; otherwise (new rows) the current match keeps its place.
    private func search(jump: Bool) {
        generation &+= 1
        task?.cancel()
        task = nil
        let query = query
        guard !query.isEmpty, let session, let detail = session.fileDiff.value,
              case .sections(let sections) = detail.content
        else {
            adopt([], capped: false, key: nil)
            return
        }
        isFresh = false
        let generation = generation
        let mode = session.diffMode
        let key = Key(loadID: detail.loadID, mode: mode)
        task = Task.detached(priority: .userInitiated) { [weak self] in
            let start = DispatchTime.now().uptimeNanoseconds
            let (found, capped) = Self.find(query, in: sections, mode: mode)
            guard !Task.isCancelled else { return }
            let ms = Double(DispatchTime.now().uptimeNanoseconds - start) / 1_000_000
            await self?.result(found, capped: capped, key: key, generation: generation, jump: jump, ms: ms)
        }
    }

    private func result(_ found: [DiffSearchMatch], capped: Bool, key: Key, generation: Int, jump: Bool, ms: Double) {
        guard generation == self.generation, shownKey == key else { return }
        adopt(found, capped: capped, key: key)
        if jump {
            current = nil
            if !found.isEmpty { go(to: 0) }
        } else if let current, current >= found.count {
            self.current = nil
        }
        UITiming.probe("diff-find", "\(query) matches=\(found.count)\(capped ? "+" : "") "
            + "current=\(current.map { $0 + 1 } ?? 0) " + String(format: "%.1f", ms))
    }

    private func adopt(_ found: [DiffSearchMatch], capped: Bool, key: Key?) {
        matches = found
        isCapped = capped
        searched = key
        isFresh = true
        token &+= 1
        bySide = Dictionary(grouping: found, by: \.side)
        offsets = [:]
        for (index, match) in found.enumerated() where offsets[match.side] == nil {
            offsets[match.side] = index
        }
        if found.isEmpty { current = nil }
    }

    /// Makes match `position` the current one and asks its table to scroll it into view.
    private func go(to position: Int) {
        guard matches.indices.contains(position) else { return }
        current = position
        revealToken &+= 1
        let match = matches[position]
        UITiming.probe("diff-find-go", "\(position + 1) of \(matches.count) row=\(match.row) \(match.column)")
    }

    /// The matches of `query` in `sections`' rows in `mode`, cards in order, top row first; and whether there were
    /// more than `limit`.
    private nonisolated static func find(_ query: String, in sections: [DiffSection],
                                         mode: DiffMode) -> ([DiffSearchMatch], Bool) {
        var found: [DiffSearchMatch] = []
        for section in sections {
            for (index, row) in section.tableRows(mode).enumerated() {
                if index % 1024 == 0, Task.isCancelled { return ([], false) }
                var lines: [(DiffRow, DiffTextColumn)] = []
                switch row {
                case .single(let line) where line.isLine:
                    lines = [(line, .unified)]
                case .pair(let old, let new):
                    if let old { lines.append((old, .old)) }
                    if let new, old?.kind != .context { lines.append((new, .new)) }
                default:
                    break
                }
                for (line, column) in lines {
                    for range in ranges(of: query, in: line.text) {
                        if found.count == limit { return (found, true) }
                        found.append(DiffSearchMatch(side: section.side, row: index, column: column, range: range))
                    }
                }
            }
        }
        return (found, false)
    }

    /// Each place of `query` in `text` (case-insensitive, not overlapping), as UTF-16 ranges.
    private nonisolated static func ranges(of query: String, in text: String) -> [NSRange] {
        let string = text as NSString
        var ranges: [NSRange] = []
        var rest = NSRange(location: 0, length: string.length)
        while rest.length > 0 {
            let range = string.range(of: query, options: .caseInsensitive, range: rest)
            guard range.location != NSNotFound, range.length > 0 else { break }
            ranges.append(range)
            rest = NSRange(location: NSMaxRange(range), length: string.length - NSMaxRange(range))
        }
        return ranges
    }
}
