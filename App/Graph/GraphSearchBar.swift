// The graph's commit search (⌘F, Edit › Find…): a repo tab's `GraphSearch` (the query, its matches off the main actor,
// the current match) and the bar that slides up over the bottom of the graph card. Going to a match selects its row as
// a click does and centres it when it is off screen; while a query has matches the other rows' text dims. No
// filtering: the lanes stay whole.
import AppKit
import HistqCore
import SwiftUI

/// Which graph rows dim while a search has matches: the rows of commits that do not match, and the WIP, worktree and
/// stash rows above them. `token` is new for each value, so the graph compares it, never the bitmap.
struct GraphDimming: Sendable {
    var token = 0
    /// The log snapshot the bitmap was computed for.
    var logGeneration = -1
    /// `matched[i]`: `commits[i]` matches. nil while nothing dims (no query, or no match).
    var matched: [Bool]?

    /// Whether `row` of `log` draws its text dimmed. Rows of commits the search has not seen yet (a later page) and
    /// any row of another snapshot do not.
    func isDimmed(row: Int, in log: LogSnapshot) -> Bool {
        guard let matched, logGeneration == log.generation else { return false }
        let index = row - log.syntheticRows.count
        guard index >= 0 else { return true }
        return index < matched.count ? !matched[index] : false
    }
}

/// A repo tab's graph search. Each query change searches the log off the main actor (`CommitSearch`, on an index of
/// the log built once per snapshot) and cancels the search before it; a new log snapshot searches again. A typed query
/// goes to its first match at or after the selected row (wrapping to the first), as GitKraken does; a new log keeps
/// the current match when its commit is still there.
@Observable
@MainActor
final class GraphSearch {
    /// The bar shows.
    private(set) var isOpen = false
    var query = "" {
        didSet {
            guard query != oldValue else { return }
            UITiming.probe("find-key", query)
            search(jump: true)
        }
    }

    /// The matching commits' indices in `log.commits`, in log order, for `searchedGeneration`'s snapshot.
    private(set) var matches: [Int] = []
    /// `matches`' index of the current match; nil until the search goes to one.
    private(set) var current: Int?
    /// `matches` belong to the current query.
    private(set) var isFresh = true
    /// What the graph dims.
    private(set) var dimming = GraphDimming()
    /// New with each open (⌘F, also while open): the bar focuses its field and selects its text.
    private(set) var focusToken = 0
    /// New with each move to a match: the graph centres the selected row when it is off screen.
    private(set) var revealToken = 0

    /// The tab's session, for its log, its selection and `selectGraph`.
    @ObservationIgnored weak var session: RepoSession?
    /// The graph table, which takes the focus back when the bar closes.
    @ObservationIgnored weak var table: NSView?

    private struct LogKey: Equatable {
        let generation: Int
        let count: Int
    }

    /// The log snapshot `matches` were computed on.
    @ObservationIgnored private var searched: LogKey?
    /// The index of `indexKey`'s snapshot, built (or being built) off the main actor.
    @ObservationIgnored private var indexKey: LogKey?
    @ObservationIgnored private var indexTask: Task<CommitSearch.Index, Never>?
    @ObservationIgnored private var searchTask: Task<Void, Never>?
    /// New for each search; a result of an older one is dropped.
    @ObservationIgnored private var generation = 0
    /// The current match's commit, kept across a new log.
    @ObservationIgnored private var currentHash: String?
    /// The typed query has not gone to a match yet (no log, no match in the pages read so far, or a new log landed
    /// before its result): the next result, also of a new log, still goes to its first match.
    @ObservationIgnored private var pendingJump = false

    /// Opens the bar (or, while open, focuses it again) and starts indexing the log, so the first keystroke only
    /// searches.
    func open() {
        isOpen = true
        focusToken &+= 1
        if let log = session?.log.value { _ = index(for: log) }
    }

    /// Esc: closes the bar, clears the query and the dimming, keeps the selection; the graph gets the focus back.
    func close() {
        guard isOpen else { return }
        isOpen = false
        query = ""
        indexTask = nil
        indexKey = nil
        guard let table, let window = table.window else { return }
        // The field editor resigns on its own turn: after it.
        DispatchQueue.main.async { [weak table] in
            guard let table, table.window === window else { return }
            window.makeFirstResponder(table)
        }
    }

    /// A new log snapshot: searches it again while a query is typed. Called by the session for every `log` change.
    func logDidChange() {
        guard isOpen, let log = session?.log.value, LogKey(generation: log.generation, count: log.commits.count) != searched
        else { return }
        search(jump: pendingJump)
    }

    /// Enter, ↓: the next match, from the last to the first.
    func next() {
        // While a new query is searched, `matches` are the last query's: its result goes to a match itself.
        guard isFresh, !matches.isEmpty else { return }
        go(to: current.map { ($0 + 1) % matches.count } ?? firstAtOrAfterSelection())
    }

    /// Shift-Enter, ↑: the previous match, from the first to the last.
    func previous() {
        guard isFresh, !matches.isEmpty else { return }
        go(to: current.map { ($0 - 1 + matches.count) % matches.count } ?? firstAtOrAfterSelection())
    }

    /// "3 of 12", "No results", or nothing without a query; with " · loading" while the log is still being read.
    var summary: String {
        guard !query.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return "" }
        let text = matches.isEmpty ? (isFresh ? "No results" : "") : "\(current.map { $0 + 1 } ?? 0) of \(matches.count)"
        let loading = session?.log.value?.isComplete == false
        return loading ? (text.isEmpty ? "loading" : text + " · loading") : text
    }

    // MARK: Searching

    /// The index of `log`'s commits: the one being built for this snapshot, else a new build off the main actor.
    private func index(for log: LogSnapshot) -> Task<CommitSearch.Index, Never> {
        let key = LogKey(generation: log.generation, count: log.commits.count)
        if key == indexKey, let indexTask { return indexTask }
        let commits = log.commits
        let task = Task.detached(priority: .userInitiated) {
            let start = DispatchTime.now().uptimeNanoseconds
            let index = CommitSearch.Index(commits)
            let ms = Double(DispatchTime.now().uptimeNanoseconds - start) / 1_000_000
            UITiming.probe("find-index", "\(commits.count) " + String(format: "%.1f", ms))
            return index
        }
        indexKey = key
        indexTask = task
        return task
    }

    /// Searches the session's log for `query` off the main actor, cancelling the search before it. `jump`: a typed
    /// query, which goes to its first match at or after the selection; otherwise (a new log) the current match stays.
    private func search(jump: Bool) {
        generation &+= 1
        searchTask?.cancel()
        searchTask = nil
        let query = query
        let blank = query.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        if jump || blank { pendingJump = !blank }
        guard !blank, let log = session?.log.value else {
            matches = []
            current = nil
            currentHash = nil
            searched = nil
            isFresh = true
            if dimming.matched != nil { dimming = GraphDimming(token: dimming.token &+ 1) }
            return
        }
        isFresh = false
        let generation = generation
        let key = LogKey(generation: log.generation, count: log.commits.count)
        let indexTask = index(for: log)
        searchTask = Task.detached(priority: .userInitiated) { [weak self] in
            let index = await indexTask.value
            guard !Task.isCancelled else { return }
            let found = CommitSearch.matches(in: index, query: query)
            guard !Task.isCancelled else { return }
            var matched: [Bool]?
            if !found.isEmpty {
                var bitmap = [Bool](repeating: false, count: key.count)
                for commit in found where commit < key.count { bitmap[commit] = true }
                matched = bitmap
            }
            await self?.adopt(found, matched: matched, key: key, generation: generation, jump: jump)
        }
    }

    private func adopt(_ found: [Int], matched: [Bool]?, key: LogKey, generation: Int, jump: Bool) {
        guard generation == self.generation, let log = session?.log.value, log.generation == key.generation,
              log.commits.count >= key.count
        else { return }
        matches = found
        searched = key
        isFresh = true
        dimming = GraphDimming(token: dimming.token &+ 1, logGeneration: key.generation, matched: matched)
        if jump {
            current = nil
            currentHash = nil
            if found.isEmpty {
                // The whole log has no match: a later log (a refresh) does not move the selection on its own.
                if log.isComplete, log.commits.count == key.count { pendingJump = false }
                return logResult()
            }
            go(to: firstAtOrAfterSelection())
        } else {
            current = currentHash.flatMap { hash in found.firstIndex { log.commits[$0].hash == hash } }
            if current == nil { currentHash = nil }
            logResult()
        }
    }

    /// `matches`' index of the first match at or after the selected row (a WIP or stash row is above every commit),
    /// else the first match.
    private func firstAtOrAfterSelection() -> Int {
        guard let session, let log = session.log.value else { return 0 }
        var anchor = 0
        if case .commit(let hash)? = session.graphSelection.first { anchor = log.commitIndex[hash] ?? 0 }
        return matches.firstIndex { $0 >= anchor } ?? 0
    }

    /// Selects match `position` as a click on its row does, and asks the graph to centre it.
    private func go(to position: Int) {
        guard let session, let log = session.log.value, matches.indices.contains(position),
              log.generation == searched?.generation, matches[position] < log.commits.count
        else { return }
        let hash = log.commits[matches[position]].hash
        current = position
        currentHash = hash
        pendingJump = false
        if session.graphSelection != [.commit(hash)] { session.selectGraph([.commit(hash)]) }
        revealToken &+= 1
        logResult()
    }

    /// DEBUG timing line: `find <query> matches=<m> current=<n> commit=<sha>` (`current` counts from 1, as the bar
    /// shows it; 0 and `-` without a current match).
    private func logResult() {
        UITiming.find("\(query) matches=\(matches.count) current=\(current.map { $0 + 1 } ?? 0) "
            + "commit=\(currentHash ?? "-")")
    }
}

/// The search bar floating over the bottom of the graph card, in a raised card: a capsule field with the magnifying
/// glass, the match count, the previous and next buttons and a close button. Enter goes to the next match, Shift-Enter
/// to the previous one, Esc closes the bar.
struct GraphSearchBar: View {
    @Bindable var search: GraphSearch
    @FocusState private var fieldFocused: Bool
    @State private var anchor = FieldAnchor.Box()

    static let height: CGFloat = 26
    /// The bar with its card and margins: what it covers of the graph's bottom (`GraphView.bottomInset`).
    static let overlayHeight: CGFloat = height + 2 * 6 + 2 * 8

    var body: some View {
        HStack(spacing: 8) {
            field
            Button { search.previous() } label: {
                Image(systemName: "chevron.up")
                    .font(.system(size: 11, weight: .semibold))
            }
            .buttonStyle(RaisedButtonStyle(height: Self.height - 2))
            .disabled(search.matches.isEmpty)
            .help("Previous match (⇧↩)")
            .accessibilityLabel("Previous match")
            Button { search.next() } label: {
                Image(systemName: "chevron.down")
                    .font(.system(size: 11, weight: .semibold))
            }
            .buttonStyle(RaisedButtonStyle(height: Self.height - 2))
            .disabled(search.matches.isEmpty)
            .help("Next match (↩)")
            .accessibilityLabel("Next match")
            Button { search.close() } label: {
                Image(systemName: "xmark")
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundStyle(.secondary)
            }
            .buttonStyle(RowIconButtonStyle())
            .padding(.horizontal, 4)
            .help("Close (Esc)")
            .accessibilityLabel("Close search")
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 6)
        // A raised card floating over the graph's last rows: opaque, so the rows under it do not show through.
        .modifier(GlassCard(cornerRadius: SettingsMetrics.cardRadius, raised: true))
        .environment(\.cardSurface, Palette.surface)
        .padding(8)
        .onAppear { focusField() }
        .onChange(of: search.focusToken) { focusField() }
    }

    private var field: some View {
        HStack(spacing: 6) {
            Image(systemName: "magnifyingglass")
                .foregroundStyle(.secondary)
                .accessibilityHidden(true)
            TextField("Find commits", text: $search.query, prompt: Text("Find commit message or hash"))
                .textFieldStyle(.plain)
                .labelsHidden()
                .autocorrectionDisabled()
                .focused($fieldFocused)
                .background(FieldAnchor(box: anchor))
                .onKeyPress(keys: [.return, .escape]) { press in handleKey(press) }
                .onExitCommand { search.close() }
            Text(search.summary)
                .font(.settingsCaption)
                .monospacedDigit()
                .foregroundStyle(.secondary)
                .lineLimit(1)
                .fixedSize()
        }
        .padding(.horizontal, 10)
        .frame(height: Self.height)
        .background(Capsule().fill(Palette.inputSurface))
        .overlay(Capsule().strokeBorder(fieldFocused ? Color.accentColor : Palette.surfaceBorder,
                                        lineWidth: fieldFocused ? 1.5 : 1))
        .focusEffectDisabled()
    }

    /// Focuses the field and selects its text, so ⌘F then typing replaces the query.
    private func focusField() {
        // The bar is installed on this turn: ask for the focus on the next one, as the palette does.
        DispatchQueue.main.async {
            fieldFocused = true
            // SwiftUI can hold the request until its next update (the next key or mouse event, so the graph kept the
            // focus after ⌘F): on the turn after, AppKit focuses the field itself when it still has not got it.
            DispatchQueue.main.async {
                guard let field = anchor.textField(), let window = field.window else { return }
                if field.currentEditor() == nil || window.firstResponder !== field.currentEditor() {
                    window.makeFirstResponder(field)
                }
                field.currentEditor()?.selectAll(nil)
            }
        }
    }

    private func handleKey(_ press: KeyPress) -> KeyPress.Result {
        // Return commits an IME syllable: it must not move to a match.
        if (NSApp.keyWindow?.firstResponder as? NSTextView)?.hasMarkedText() == true { return .ignored }
        switch press.key {
        case .escape:
            search.close()
        case .return:
            guard press.phase == .down || press.phase == .repeat else { return .handled }
            if press.modifiers.contains(.shift) { search.previous() } else { search.next() }
        default:
            return .ignored
        }
        return .handled
    }
}

/// An empty AppKit view behind the search field, at its frame: finds the field's `NSTextField` (the editable one under
/// it in the window) for `GraphSearchBar.focusField`'s AppKit fallback. Clicks pass through it.
private struct FieldAnchor: NSViewRepresentable {
    let box: Box

    final class Box {
        weak var view: NSView?

        /// The editable text field under the anchor, nil before the anchor is in a window.
        func textField() -> NSTextField? {
            guard let view, let content = view.window?.contentView else { return nil }
            return Self.field(in: content, under: view.convert(view.bounds, to: nil))
        }

        private static func field(in view: NSView, under frame: NSRect) -> NSTextField? {
            for subview in view.subviews {
                if let field = subview as? NSTextField, field.isEditable,
                   field.convert(field.bounds, to: nil).intersects(frame) {
                    return field
                }
                if let match = field(in: subview, under: frame) { return match }
            }
            return nil
        }
    }

    private final class PassThroughView: NSView {
        override func hitTest(_ point: NSPoint) -> NSView? { nil }
    }

    func makeNSView(context: Context) -> NSView {
        let view = PassThroughView()
        box.view = view
        return view
    }

    func updateNSView(_ view: NSView, context: Context) {
        box.view = view
    }
}
