// The interactive rebase and squash modals (task 9.3; in-window `ModalCard`s since 9.6). "Interactive Rebase from Here…" on a commit lists that commit
// and every later one of the current branch, oldest first (the order git replays them): each row has an action
// (pick, reword, edit, squash, fixup, drop), rows drag to a new order, and a reword row edits its message in place.
// "Squash N Commits…" on a run of selected commits shows the message the squashed commit gets, editable as the commit
// box's two fields: the summary ("Squash N commits with detailed messages in body") and the description (every
// commit's message, oldest first); Generate asks the AI for both from the commits' messages. The sheet opens in the click's frame with skeleton rows; `RebaseTodo` reads the commits off the
// main actor. Start runs the todo as a write (`RepoSession.startRebase`): a conflict or an `edit` stop leaves the rebase
// in progress, and the operation banner and the conflict editor take over.
import HistqCore
import SwiftUI

/// A rebase sheet asked for by a menu, the palette or a launch flag.
struct RebaseRequest: Identifiable {
    enum Kind: Equatable, Sendable {
        /// Every commit from this one (full id) to HEAD.
        case fromCommit(String)
        /// The selected commits (full ids), folded into the oldest.
        case squash([String])
        /// The current branch's commits that this commit (full id, the tip of branch `name`) lacks, replayed onto it.
        case onto(String, name: String)
    }

    let id = UUID()
    let kind: Kind
    /// A `.fromCommit` sheet's row (full id) that starts as reword.
    var reword: String? = nil
}

struct InteractiveRebaseView: View {
    let session: RepoSession
    let request: RebaseRequest
    let onClose: () -> Void

    @State private var todo: Loadable<RebaseTodo> = .loading
    /// The rows as the user arranged them.
    @State private var items: [RebaseTodo.Item] = []
    /// The squash sheet's message, as the commit box splits it.
    @State private var summary = ""
    @State private var description = ""

    static let summaryLimit = 72

    private var isSquash: Bool {
        if case .squash = request.kind { true } else { false }
    }

    var body: some View {
        ModalCard(title: title, subtitle: subtitle, systemImage: isSquash ? "arrow.triangle.merge" : "arrow.triangle.swap",
                  width: 600, takesFocus: true) {
            switch todo {
            case .idle, .loading:
                SectionCard("Commits") { RebaseSkeleton(rows: placeholderRows) }
            case .failed(let text):
                SectionCard("Commits") { ErrorText(message: text) }
            case .loaded:
                if isSquash { squashCards } else { rebaseCard }
            }
            ErrorText(message: problem)
                .padding(.horizontal, 6)
        } actions: {
            Button("Cancel", action: onClose)
                .buttonStyle(RowTextButtonStyle(formRow: true))
                .keyboardShortcut(.cancelAction)
            // Never one Return away: a rebase rewrites the branch.
            Button(isSquash ? "Squash" : "Start Rebase", action: start)
                .buttonStyle(RowTextButtonStyle(formRow: true, prominent: true))
                .disabled(todo.value == nil || problem != nil)
        }
        .task { await load() }
    }

    // MARK: Content

    private var title: String {
        switch request.kind {
        case .fromCommit(let commit):
            "Interactive rebase of \(session.currentBranch ?? "HEAD") from \(commit.prefix(7))"
        case .squash(let commits):
            "Squash \(commits.count) commits"
        case .onto(_, let name):
            "Interactive rebase of \(session.currentBranch ?? "HEAD") onto \(name)"
        }
    }

    private var subtitle: String {
        isSquash
            ? "The commits become one, with the message below; the commits after them are replayed on top."
            : "Oldest first: the top row is replayed first. Drag the rows to reorder them."
    }

    private var placeholderRows: Int {
        if case .squash(let commits) = request.kind { commits.count } else { 4 }
    }

    /// The rows: action, short id, subject; a reword row adds its message editor.
    private var rebaseCard: some View {
        SectionCard("Commits", systemImage: "list.bullet", count: items.count, contentPadding: 6) {
            List {
                ForEach($items) { $item in
                    RebaseRow(item: $item) { improve(item) }
                        .listRowBackground(Color.clear)
                        .listRowSeparator(.hidden)
                }
                .onMove { items.move(fromOffsets: $0, toOffset: $1) }
            }
            .listStyle(.plain)
            .scrollContentBackground(.hidden)
            // Shrinks (the list scrolls) when the window is too short for every row.
            .frame(minHeight: 76, maxHeight: listHeight)
        }
    }

    /// A row is about 38 pt, a reword row's editor adds about 80; at most 380 (the list scrolls).
    private var listHeight: CGFloat {
        let rewords = items.filter { $0.action == .reword }.count
        return min(380, CGFloat(items.count) * 38 + CGFloat(rewords) * 80 + 8)
    }

    /// The squashed commits (read only), then the message card.
    @ViewBuilder private var squashCards: some View {
        let count = squashCount
        SectionCard("Commits", systemImage: "list.bullet", count: count) {
            VStack(alignment: .leading, spacing: 6) {
                ForEach(items.prefix(count)) { item in
                    HStack(spacing: 8) {
                        Text(item.commit.prefix(7))
                            .font(.body.monospaced())
                            .foregroundStyle(.secondary)
                        Text(item.subject)
                            .lineLimit(1)
                            .truncationMode(.tail)
                    }
                }
            }
        }
        SectionCard("Message", systemImage: "text.alignleft") {
            VStack(alignment: .leading, spacing: 8) {
                HStack(spacing: 8) {
                    TextField("Summary", text: $summary)
                        .textFieldStyle(.settings)
                    Text("\(summary.count)/\(Self.summaryLimit)")
                        .font(.settingsCaption)
                        .monospacedDigit()
                        .foregroundStyle(summary.count > Self.summaryLimit
                            ? Color(nsColor: Palette.graphLanes[6]) : .secondary)
                        .help("Keep the summary within \(Self.summaryLimit) characters")
                }
                TextEditor(text: $description)
                    .font(.body)
                    .settingsTextEditor()
                    .frame(height: 120)
                    .overlay(alignment: .topLeading) {
                        if description.isEmpty {
                            Text("Description")
                                .foregroundStyle(.tertiary)
                                .padding(.horizontal, 11)
                                .padding(.vertical, 8)
                                .allowsHitTesting(false)
                        }
                    }
            }
            .padding(.top, SectionCardMetrics.accessoryGap)
        } accessory: {
            AIHookButton(title: "Generate", systemImage: "sparkles",
                         help: "Write the squash's message from the squashed commits' messages with AI",
                         seam: "squash-message", small: true, action: generate)
        }
    }

    /// The summary, a blank line and the description (when there is one), as the commit box writes them.
    private var message: String {
        let summary = summary.trimmingCharacters(in: .whitespacesAndNewlines)
        let description = description.trimmingCharacters(in: .whitespacesAndNewlines)
        return description.isEmpty ? summary : summary + "\n\n" + description
    }

    /// The squashed commits' messages, oldest first: each subject as a bullet, its body indented under it.
    static func squashDescription(_ items: some Sequence<RebaseTodo.Item>) -> String {
        items.map { item in
            let text = item.message.trimmingCharacters(in: .whitespacesAndNewlines)
            let body = text.range(of: "\n\n").map { String(text[$0.upperBound...]) } ?? ""
            let lines = body.isEmpty ? [] : body.components(separatedBy: "\n").map { $0.isEmpty ? "" : "  " + $0 }
            return (["* " + item.subject] + lines).joined(separator: "\n")
        }
        .joined(separator: "\n")
    }

    /// The squash todo picks the oldest and squashes the others; the commits after them stay picks.
    private var squashCount: Int {
        if case .squash(let commits) = request.kind { min(commits.count, items.count) } else { 0 }
    }

    /// What keeps Start disabled (the core refuses the same), shown under the cards.
    private var problem: String? {
        guard todo.value != nil else { return nil }
        // In both modes: the first kept row has nothing to fold into when it is a squash or a fixup.
        if let first = items.first(where: { $0.action != .drop }), [.squash, .fixup].contains(first.action) {
            return RebaseTodoError.nothingToFoldInto(first.commit).message
        }
        if isSquash {
            return summary.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                ? RebaseTodoError.emptyMessage(items.first?.commit ?? "").message : nil
        }
        if let empty = items.first(where: {
            $0.action == .reword && ($0.newMessage ?? "").trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        }) {
            return RebaseTodoError.emptyMessage(empty.commit).message
        }
        return nil
    }

    // MARK: Actions

    private func load() async {
        do {
            let loaded = try await session.loadRebaseTodo(request.kind)
            items = loaded.items
            if isSquash {
                let squashed = items.prefix(squashCount)
                summary = "Squash \(squashCount) commits with detailed messages in body"
                description = Self.squashDescription(squashed)
            }
            if !isSquash, let reword = request.reword, let index = items.firstIndex(where: { $0.commit == reword }) {
                items[index].setAction(.reword)
            }
            #if DEBUG
            // `-HistqRewordRow <n>` (1-based): that row becomes reword as its action menu would, for the Improve hook.
            if !isSquash, let row = AppState.launchFlag("-HistqRewordRow").flatMap(Int.init),
               items.indices.contains(row - 1) {
                items[row - 1].setAction(.reword)
            }
            #endif
            todo = .loaded(loaded)
        } catch {
            if !(error is CancellationError) { todo = .failed(RepoSession.writeMessage(for: error)) }
        }
    }

    /// A reword row's Improve: the AI card opens over the sheet; Apply replaces the row's new message (nothing when
    /// the row is gone or no longer reword). Sends the edited message, or the original when the editor is blank.
    private func improve(_ item: RebaseTodo.Item) {
        let edited = item.newMessage ?? ""
        let message = edited.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? item.message : edited
        let id = item.id
        session.startAI(.improveMessage(hash: item.commit, message: message)) { answer in
            guard let index = items.firstIndex(where: { $0.id == id }), items[index].action == .reword else { return }
            items[index].newMessage = answer
        }
    }

    /// The Message card's Generate: the AI card opens over the sheet with the squashed commits' original messages
    /// (never the fields, whose default summary would only be echoed); Apply puts the answer's first line in the
    /// summary and the rest, after the blank line, in the description.
    private func generate() {
        session.startAI(.squashMessage(messages: items.prefix(squashCount).map(\.message))) { answer in
            var lines = answer.split(separator: "\n", omittingEmptySubsequences: false).map {
                $0.trimmingCharacters(in: CharacterSet(charactersIn: "\r"))
            }
            summary = lines.isEmpty ? "" : lines.removeFirst().trimmingCharacters(in: .whitespaces)
            description = lines.joined(separator: "\n").trimmingCharacters(in: .whitespacesAndNewlines)
        }
    }

    private func start() {
        guard var run = todo.value, problem == nil else { return }
        run.items = items
        if isSquash, !run.items.isEmpty { run.items[0].newMessage = message }
        session.startRebase(run)
        onClose()
    }
}

// MARK: - Rows

/// One commit of the todo: its action (a capsule menu), short id and subject (struck through when dropped); a reword
/// row shows its message editor under it.
private struct RebaseRow: View {
    @Binding var item: RebaseTodo.Item
    let onImprove: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 8) {
                Image(systemName: "line.3.horizontal")
                    .foregroundStyle(.tertiary)
                    .help("Drag to reorder")
                CapsuleMenuPicker(label: "Action", selection: action, title: Text(item.action.title)) {
                    ForEach(RebaseTodo.Action.allCases, id: \.self) { action in
                        Text(action.title).tag(action)
                    }
                }
                .help(item.action.help)
                Text(item.commit.prefix(7))
                    .font(.body.monospaced())
                    .foregroundStyle(.secondary)
                Text(item.subject)
                    .lineLimit(1)
                    .truncationMode(.tail)
                    .strikethrough(item.action == .drop)
                    .foregroundStyle(item.action == .drop ? .secondary : .primary)
                Spacer(minLength: 0)
            }
            if item.action == .reword {
                HStack(alignment: .top, spacing: 6) {
                    TextEditor(text: newMessage)
                        .font(.body)
                        .frame(height: 64)
                        .settingsTextEditor()
                    AIHookButton(title: "Improve", systemImage: "sparkles",
                                 help: "Improve this commit message with AI", seam: "improve-message", small: true,
                                 action: onImprove)
                }
            }
        }
        .padding(.vertical, 2)
    }

    private var action: Binding<RebaseTodo.Action> {
        Binding { item.action } set: { item.setAction($0) }
    }

    private var newMessage: Binding<String> {
        Binding { item.newMessage ?? "" } set: { item.newMessage = $0 }
    }
}

/// The rows' shape while the commits load: action capsule, id, subject; the spinner only after 150 ms.
private struct RebaseSkeleton: View {
    let rows: Int

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            ForEach(0..<max(rows, 1), id: \.self) { row in
                HStack(spacing: 10) {
                    SkeletonLine(width: 70, height: 14)
                    SkeletonLine(width: 52, height: 12)
                    SkeletonLine(fraction: [0.7, 0.5, 0.85, 0.6][row % 4], height: 12)
                }
            }
        }
        .padding(.vertical, 4)
        .overlay { DelayedSpinner(detail: "rebase") }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("Loading")
    }
}

extension RebaseTodo.Item {
    /// The action menu's change: a row that becomes reword starts from its message; a row that leaves it drops the
    /// new message, which the todo would otherwise still apply to a pick.
    fileprivate mutating func setAction(_ action: RebaseTodo.Action) {
        self.action = action
        if action == .reword {
            if newMessage == nil { newMessage = message.trimmingCharacters(in: .newlines) }
        } else {
            newMessage = nil
        }
    }
}

extension RebaseTodo.Action {
    var title: String {
        switch self {
        case .pick: "Pick"
        case .reword: "Reword"
        case .edit: "Edit"
        case .squash: "Squash"
        case .fixup: "Fixup"
        case .drop: "Drop"
        }
    }

    var help: String {
        switch self {
        case .pick: "Keep the commit as it is."
        case .reword: "Keep the commit with a new message."
        case .edit: "Stop after this commit to amend it; Continue goes on."
        case .squash: "Fold into the commit above, keeping both messages."
        case .fixup: "Fold into the commit above, keeping only its message."
        case .drop: "Leave the commit out."
        }
    }
}
