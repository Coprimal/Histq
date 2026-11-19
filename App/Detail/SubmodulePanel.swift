// A submodule in the detail panel (a click on its sidebar row): its state, the commit the repo records for it and the
// one its checkout is on, the commits between them, and its actions. The same view with no detail is its placeholder,
// so the cards keep their place when the read is in. Also a submodule row's pointer change in the diff panel
// (`SubmoduleChangeCard`).
import HistqCore
import SwiftUI

/// What `SubmoduleStatusPanel` shows, read off the main actor: the submodule as listed, and in its checkout the
/// recorded and checked-out commits and the commits between them.
struct SubmoduleDetail: Sendable, Equatable {
    let submodule: Submodule
    /// Inside another submodule: its pointer lives in that one, so the actions on this repo's index are left out.
    let isNested: Bool
    /// Nil when there is no checkout or it lacks the commit.
    let recorded: SubmoduleChange.Commit?
    /// Nil when there is no checkout.
    let checkedOut: SubmoduleChange.Commit?
    /// Recorded → checked-out commit; nil unless the checkout is on another commit.
    let change: SubmoduleChange?

    /// Inside another submodule of `list`.
    static func isNested(_ path: String, in list: [Submodule]) -> Bool {
        list.contains { path.hasPrefix($0.path + "/") }
    }
}

struct SubmoduleStatusPanel: View {
    let session: RepoSession
    let path: String
    /// Nil while it is read (skeleton lines).
    let detail: SubmoduleDetail?
    @AppStorage(PrefKey.dateFormat.rawValue, store: Preferences.defaults) private var dateFormat = "MM/dd/yy @ HH:mm"
    @Environment(\.textSize) private var textSize

    var body: some View {
        VStack(spacing: SectionCardMetrics.spacing) {
            SectionCard(path, systemImage: SidebarMetrics.submoduleImage) {
                VStack(alignment: .leading, spacing: 4) {
                    if let detail {
                        let state = Self.state(detail)
                        Text(state.position)
                            .font(.body.weight(.medium))
                            .lineLimit(1)
                            .help(state.position)
                        Text(state.checkout)
                            .font(.settingsCaption)
                            .lineLimit(1)
                        Text(detail.submodule.url ?? "No URL in .gitmodules")
                            .font(.settingsCaption)
                            .foregroundStyle(.secondary)
                            .lineLimit(1)
                            .truncationMode(.middle)
                            .textSelection(.enabled)
                    } else {
                        line(.body.weight(.medium), fraction: 0.55)
                        line(.settingsCaption, fraction: 0.4)
                        line(.settingsCaption, fraction: 0.7)
                    }
                    // The placeholder lays out the same buttons (from the listed submodule), hidden under bars.
                    let actions = detail.map(actions) ?? placeholderActions
                    VStack(alignment: .leading, spacing: 6) {
                        buttonRow(actions.pointer, skeleton: detail == nil)
                        buttonRow(actions.folder, skeleton: detail == nil)
                    }
                    .padding(.top, 4)
                }
                .frame(maxWidth: .infinity, alignment: .leading)
            }
            SectionCard("Recorded commit", systemImage: "smallcircle.filled.circle") {
                commitLine(detail?.recorded, sha: detail?.submodule.recordedCommit,
                           missing: "Not in a local clone of the submodule")
            }
            SectionCard("Checked out commit", systemImage: "lucide-git-branch") {
                commitLine(detail?.checkedOut, sha: detail.flatMap(Self.head), missing: "No checkout")
            }
            SectionCard("Commits between", systemImage: "clock", count: detail?.change?.commits.count,
                        countIsLoading: detail == nil, contentPadding: 6) {
                commits
                    .frame(maxHeight: .infinity, alignment: .top)
            }
        }
    }

    // MARK: State

    private static func head(_ detail: SubmoduleDetail) -> String? {
        if case .checkedOut(let head, _) = detail.submodule.state { head } else { nil }
    }

    /// Its place against the recorded commit ("1 commit ahead of the recorded commit", "Not initialized"), then its
    /// checkout ("On branch main · 3 uncommitted changes", "Detached HEAD", "No checkout").
    static func state(_ detail: SubmoduleDetail) -> (position: String, checkout: String) {
        let submodule = detail.submodule
        let branch: String?
        switch submodule.state {
        case .notInitialized: return ("Not initialized", "No checkout")
        case .notCheckedOut: return ("Not checked out", "No checkout")
        case .checkedOut(_, let name): branch = name
        }
        let position: String
        if let change = detail.change {
            if !change.available {
                position = "On another commit than the recorded one"
            } else {
                let ahead = count(change.ahead, "commit") + " ahead"
                let behind = count(change.behind, "commit") + " behind"
                position = switch (change.ahead > 0, change.behind > 0) {
                case (true, true): "\(ahead) of and \(behind) the recorded commit"
                case (true, false): "\(ahead) of the recorded commit"
                case (false, true): "\(behind) the recorded commit"
                case (false, false): "On another commit than the recorded one"
                }
            }
        } else {
            position = "On the recorded commit"
        }
        var checkout = [branch.map { "On branch \($0)" } ?? "Detached HEAD"]
        if submodule.changeCount > 0 { checkout.append(count(submodule.changeCount, "uncommitted change")) }
        return (position, checkout.joined(separator: " · "))
    }

    private static func count(_ value: Int, _ noun: String) -> String {
        value == 1 ? "1 \(noun)" : "\(value) \(noun)s"
    }

    // MARK: Actions

    private struct Action: Identifiable {
        let title: String
        var prominent = false
        let help: String
        let perform: @MainActor () -> Void
        var id: String { title }
    }

    /// The buttons in two rows, so the card keeps its height whatever the state: the pointer's (Initialize or Update,
    /// Stage New Pointer once the checkout moved), then the folder's (Open in New Tab, Remove…). Initialize, Update,
    /// Stage New Pointer and Remove act on this repo's index, so a nested submodule has only Open in New Tab.
    private func actions(_ detail: SubmoduleDetail) -> (pointer: [Action], folder: [Action]) {
        actions(detail.submodule, isNested: detail.isNested)
    }

    /// The listed submodule's buttons while its detail is read; a clean checkout's before the list is in.
    private var placeholderActions: (pointer: [Action], folder: [Action]) {
        guard let list = session.submodules.value, let submodule = list.first(where: { $0.path == path }) else {
            let placeholder = { (title: String) in Action(title: title, help: "") {} }
            return (["Update"].map(placeholder), ["Open in New Tab", "Remove…"].map(placeholder))
        }
        return actions(submodule, isNested: SubmoduleDetail.isNested(path, in: list))
    }

    private func actions(_ submodule: Submodule, isNested: Bool) -> (pointer: [Action], folder: [Action]) {
        let isCheckedOut = if case .checkedOut = submodule.state { true } else { false }
        var pointer: [Action] = []
        var folder: [Action] = []
        if !isNested {
            let verb = isCheckedOut ? "Update" : "Initialize"
            pointer.append(Action(
                title: verb, prominent: true,
                help: isCheckedOut ? "Check out the recorded commit" : "Clone it and check out the recorded commit"
            ) { [session, path] in
                session.run(.updateSubmodules([path], initialize: !isCheckedOut), title: "\(verb) submodule \(path)")
            })
            if submodule.isMoved {
                pointer.append(Action(title: "Stage New Pointer",
                                      help: "Record the checked-out commit in this repository's index") {
                    [session, path] in
                    session.run(.stage([path]), title: "Stage submodule pointer \(path)")
                })
            }
        }
        if isCheckedOut {
            folder.append(Action(title: "Open in New Tab", help: "Open the submodule's folder in a new tab") {
                [session, path] in
                session.openSubmodule(path)
            })
        }
        if !isNested {
            folder.append(Action(title: "Remove…", help: "Remove the submodule from this repository") {
                RepoMenus.confirmRemoveSubmodule(path, session)
            })
        }
        return (pointer, folder)
    }

    /// One row of buttons, a button tall even when empty. In the placeholder they are laid out invisible, under bars.
    private func buttonRow(_ actions: [Action], skeleton: Bool) -> some View {
        ZStack(alignment: .leading) {
            // The row's height when it has no button.
            Button("Update") {}
                .buttonStyle(RowTextButtonStyle(formRow: true))
                .fixedSize()
                .hidden()
                .disabled(true)
                .accessibilityHidden(true)
            HStack(spacing: 6) {
                ForEach(actions) { action in
                    Button(action.title, action: action.perform)
                        .buttonStyle(RowTextButtonStyle(formRow: true, prominent: action.prominent && !skeleton))
                        .fixedSize()
                        .help(action.help)
                        .disabled(skeleton)
                        .opacity(skeleton ? 0 : 1)
                        .overlay { if skeleton { SkeletonLine(fraction: 1, height: 14) } }
                }
            }
        }
    }

    // MARK: Commits

    /// A commit's short sha, subject and date; the sha alone when the checkout lacks it, `missing` with no sha.
    @ViewBuilder private func commitLine(_ commit: SubmoduleChange.Commit?, sha: String?, missing: String)
        -> some View
    {
        VStack(alignment: .leading, spacing: 4) {
            if detail == nil {
                line(.body, fraction: 0.6)
                line(.settingsCaption, fraction: 0.35)
            } else {
                HStack(spacing: 8) {
                    if let sha {
                        Text(sha.prefix(7))
                            .font(.body.monospaced())
                            .textSelection(.enabled)
                    }
                    Text(commit?.subject ?? (sha == nil ? missing : ""))
                        .font(.body)
                        .foregroundStyle(commit == nil ? .secondary : .primary)
                        .lineLimit(1)
                        .truncationMode(.tail)
                }
                Text(commit.map { "\($0.author) · \(format($0.date))" } ?? (sha == nil ? " " : missing))
                    .font(.settingsCaption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    @ViewBuilder private var commits: some View {
        if let detail {
            if Self.head(detail) == nil {
                note("No checkout")
            } else if let change = detail.change {
                if !change.available {
                    note("These commits are not in the submodule's clone: fetch it to see them.")
                } else {
                    CardScrollView {
                        VStack(alignment: .leading, spacing: 0) {
                            ForEach(change.commits) { commit in
                                SubmoduleCommitRow(commit: commit, newHelp: "In the checkout, not in the recorded commit",
                                                   oldHelp: "In the recorded commit, not in the checkout")
                            }
                        }
                    }
                }
            } else {
                note("None: the checkout is on the recorded commit")
            }
        } else {
            SkeletonFileRows(fractions: [0.6, 0.45, 0.7])
        }
    }

    private func note(_ text: String) -> some View {
        Text(text)
            .font(textSize.body)
            .foregroundStyle(.secondary)
            .padding(.horizontal, 6)
            .frame(minHeight: FileListView<EmptyView>.rowHeight(textSize))
    }

    // MARK: Skeleton

    /// A skeleton bar as tall as a line of `font`.
    private func line(_ font: Font, fraction: CGFloat) -> some View {
        Text(verbatim: "M")
            .font(font)
            .hidden()
            .frame(maxWidth: .infinity, alignment: .leading)
            .overlay(alignment: .leading) {
                SkeletonLine(fraction: fraction, height: 11)
            }
    }

    private func format(_ date: Date) -> String {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: Locale.current.identifier)
        formatter.dateFormat = dateFormat
        return formatter.string(from: date)
    }
}

// MARK: - Pointer change

/// One side of a submodule row's change (`FileDiffDetail.Content.submodule`): the commit its pointer moved from and
/// to, and in the submodule's checkout the commits between.
struct SubmodulePointer: Sendable, Identifiable {
    /// `.commit` (a commit's or a stash's row), `.unstaged` (the index → the checkout) or `.staged` (HEAD → the index).
    let side: DiffSide
    /// Nil: the submodule is added on this side.
    let from: String?
    /// Nil: the submodule is removed.
    let to: String?
    /// The submodule's folder has its own `.git`: its commits can be read and it opens in a tab.
    let isCheckedOut: Bool
    /// `from` → `to` read in the checkout; nil without one, or for a removed submodule.
    let change: SubmoduleChange?
    /// The checkout's uncommitted files, untracked ones too (the unstaged side only).
    let uncommitted: Int

    var id: DiffSide { side }
}

/// A submodule row's pointer change, the body of its diff card: "Submodule vendor/lib: abc1234 → def5678", how it
/// moved ("3 commits ahead", "Added at def5678", "Removed"), the checkout's uncommitted files, Open Submodule (and for
/// an unstaged change Stage and Discard…), then the commits between with their refs. No lines: nothing to stage by
/// hunk or line. `pointer` nil is its placeholder: the same lines and buttons under skeleton bars.
struct SubmoduleChangeCard: View {
    let session: RepoSession
    let path: String
    let pointer: SubmodulePointer?
    /// A WIP row: the placeholder lays out an unstaged change's buttons.
    let isWIP: Bool
    @Environment(\.textSize) private var textSize

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            if let pointer {
                let title = Self.title(path, pointer)
                Text(title)
                    .font(.body.weight(.medium))
                    .lineLimit(1)
                    .truncationMode(.middle)
                    .help(title)
                    .textSelection(.enabled)
                Text(Self.state(pointer))
                    .font(.settingsCaption)
                    .lineLimit(1)
                if pointer.uncommitted > 0 {
                    Text(pointer.uncommitted == 1 ? "1 uncommitted file" : "\(pointer.uncommitted) uncommitted files")
                        .font(.settingsCaption)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }
            } else {
                line(.body.weight(.medium), fraction: 0.55)
                line(.settingsCaption, fraction: 0.35)
            }
            buttonRow
                .padding(.top, 4)
            commits
                .padding(.top, 6)
                .frame(maxHeight: .infinity, alignment: .top)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
    }

    // MARK: Text

    /// "Submodule vendor/lib: abc1234 → def5678"; one sha when added or removed.
    static func title(_ path: String, _ pointer: SubmodulePointer) -> String {
        "Submodule \(path): " + [pointer.from, pointer.to].compactMap { $0.map { String($0.prefix(7)) } }
            .joined(separator: " → ")
    }

    /// How the pointer moved: "Removed", "Added at def5678", "3 commits ahead", "2 commits behind (rewind)", both, or
    /// "Moved to another commit" when the checkout can't tell.
    static func state(_ pointer: SubmodulePointer) -> String {
        guard let to = pointer.to else { return "Removed" }
        guard pointer.from != nil else { return "Added at \(to.prefix(7))" }
        guard let change = pointer.change, change.available else { return "Moved to another commit" }
        let ahead = count(change.ahead, "commit") + " ahead"
        return switch (change.ahead > 0, change.behind > 0) {
        case (true, false): ahead
        case (false, true): count(change.behind, "commit") + " behind (rewind)"
        case (true, true): "\(ahead), \(change.behind) behind"
        case (false, false): "Moved to another commit"
        }
    }

    private static func count(_ value: Int, _ noun: String) -> String {
        value == 1 ? "1 \(noun)" : "\(value) \(noun)s"
    }

    // MARK: Buttons

    private struct Action: Identifiable {
        let title: String
        var prominent = false
        let help: String
        let perform: @MainActor () -> Void
        var id: String { title }
    }

    /// Open Submodule (a checkout), then for an unstaged pointer move Stage and Discard….
    private var actions: [Action] {
        guard let pointer else {
            let titles = isWIP ? ["Open Submodule", "Stage", "Discard…"] : ["Open Submodule"]
            return titles.map { Action(title: $0, help: "") {} }
        }
        var actions: [Action] = []
        if pointer.isCheckedOut {
            actions.append(Action(title: "Open Submodule", help: "Open the submodule's folder in a new tab") {
                [session, path] in
                session.openSubmodule(path)
            })
        }
        if pointer.side == .unstaged, let from = pointer.from, let to = pointer.to, from != to {
            actions.append(Action(title: "Stage", prominent: true,
                                  help: "Record the checked-out commit in this repository's index") { [session, path] in
                session.run(.stage([path]), title: "Stage submodule pointer \(path)")
            })
            actions.append(Action(title: "Discard…", help: "Check out the commit the index records again") {
                [session, path] in
                session.confirm("Discard the changes to \(path)?",
                                message: "Puts \(path) back on \(from.prefix(7)). Commits only on its current detached "
                                    + "HEAD stay in its reflog.",
                                button: "Discard", write: .discard([path]), operation: "Discard submodule \(path)")
            })
        }
        return actions
    }

    /// The buttons, a button tall even when empty; in the placeholder laid out invisible, under bars.
    private var buttonRow: some View {
        let skeleton = pointer == nil
        return ZStack(alignment: .leading) {
            Button("Stage") {}
                .buttonStyle(RowTextButtonStyle(formRow: true))
                .fixedSize()
                .hidden()
                .disabled(true)
                .accessibilityHidden(true)
            HStack(spacing: 6) {
                ForEach(actions) { action in
                    Button(action.title, action: action.perform)
                        .buttonStyle(RowTextButtonStyle(formRow: true, prominent: action.prominent && !skeleton))
                        .fixedSize()
                        .help(action.help)
                        .disabled(skeleton)
                        .opacity(skeleton ? 0 : 1)
                        .overlay { if skeleton { SkeletonLine(fraction: 1, height: 14) } }
                }
            }
        }
    }

    // MARK: Commits

    @ViewBuilder private var commits: some View {
        if let pointer {
            if pointer.to == nil {
                EmptyView()
            } else if !pointer.isCheckedOut {
                note("Not checked out: the commits between can't be listed")
            } else if let change = pointer.change, change.available {
                CardScrollView {
                    VStack(alignment: .leading, spacing: 0) {
                        ForEach(change.commits) { commit in
                            SubmoduleCommitRow(commit: commit, newHelp: "In the new pointer, not in the old one",
                                               oldHelp: "In the old pointer, not in the new one")
                        }
                    }
                }
            } else {
                note("These commits are not in the submodule's clone: fetch it to see them.")
            }
        } else {
            SkeletonFileRows(fractions: [0.6, 0.45, 0.7])
        }
    }

    private func note(_ text: String) -> some View {
        Text(text)
            .font(textSize.body)
            .foregroundStyle(.secondary)
            .frame(minHeight: FileListView<EmptyView>.rowHeight(textSize))
    }

    /// A skeleton bar as tall as a line of `font`.
    private func line(_ font: Font, fraction: CGFloat) -> some View {
        Text(verbatim: "M")
            .font(font)
            .hidden()
            .frame(maxWidth: .infinity, alignment: .leading)
            .overlay(alignment: .leading) {
                SkeletonLine(fraction: fraction, height: 11)
            }
    }
}

/// A commit between two pointers of a submodule: a plus when the newer side has it, a minus when the pointer moved
/// back past it (`newHelp` / `oldHelp` say which side is which), its short sha, subject, refs and date.
struct SubmoduleCommitRow: View {
    let commit: SubmoduleChange.Commit
    let newHelp: String
    let oldHelp: String
    @AppStorage(PrefKey.dateFormat.rawValue, store: Preferences.defaults) private var dateFormat = "MM/dd/yy @ HH:mm"
    @Environment(\.textSize) private var textSize

    var body: some View {
        HStack(spacing: 8) {
            Image(systemName: commit.isNew ? "plus.circle" : "minus.circle")
                .foregroundStyle(commit.isNew ? Color(nsColor: Palette.graphLanes[0]) : Color.secondary)
                .help(commit.isNew ? newHelp : oldHelp)
            Text(commit.sha.prefix(7))
                .font(textSize.caption.monospaced())
                .foregroundStyle(.secondary)
            Text(commit.subject)
                .font(textSize.body)
                .lineLimit(1)
                .truncationMode(.tail)
            ForEach(commit.refs, id: \.self) { ref in
                Text(ref)
                    .font(textSize.caption)
                    .lineLimit(1)
                    .padding(.horizontal, 6)
                    .padding(.vertical, 1)
                    .background(Capsule().fill(Color.accentColor.opacity(0.25)))
                    .fixedSize()
            }
            Spacer(minLength: 8)
            Text(format(commit.date))
                .font(textSize.caption)
                .foregroundStyle(.secondary)
                .lineLimit(1)
                .fixedSize()
        }
        .padding(.horizontal, 6)
        .frame(height: FileListView<EmptyView>.rowHeight(textSize))
        .accessibilityElement(children: .combine)
    }

    private func format(_ date: Date) -> String {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: Locale.current.identifier)
        formatter.dateFormat = dateFormat
        return formatter.string(from: date)
    }
}
