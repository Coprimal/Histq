// The working tree in the detail panel, each part in its own card: the conflicted files (open the conflict editor,
// stage), the unstaged files (stage, discard), the staged files (unstage), and the commit box (summary with a 72-character counter, description, Amend, Commit / ⌘↩, and the AI buttons Explain and Generate Message).
// Every write goes through `RepoSession.perform` (write environment, off the main actor); the control that started
// it shows a spinner at once, and an error shows in its card.
import HistqCore
import SwiftUI

/// The commit box's text, kept on the session while another row is selected.
struct CommitDraft {
    var summary = ""
    var description = ""
    var amend = false
    /// What the user had typed before Amend filled in HEAD's message; restored when Amend is turned off.
    var savedSummary = ""
    var savedDescription = ""
}

/// The WIP detail, from the session's live `status`.
struct WIPPanel: View {
    let session: RepoSession
    /// The controls whose write is running.
    @State private var busy: Set<Busy> = []
    @State private var errors: [Part: String] = [:]
    /// The unstaged files' sizes on disk, by path (read off the main actor).
    @State private var sizes: [String: Int64] = [:]
    @AppStorage(PrefKey.showFileSizes.rawValue, store: Preferences.defaults) private var showsSizes = true
    @AppStorage(PrefKey.commitBoxPosition.rawValue, store: Preferences.defaults)
    private var commitBoxPosition = "bottom"
    /// The window's modal (`ModalHost`) asks before a discard.
    @Environment(WindowModel.self) private var model

    fileprivate enum Busy: Hashable {
        case stage(String), unstage(String), discard(String), stageAll, unstageAll, commit, amendMessage
    }

    fileprivate enum Part: Hashable {
        case conflicted, unstaged, staged, commit
    }

    var body: some View {
        let status = session.status.value
        let conflicted = status.map(Self.conflicted) ?? []
        let unstaged = status.map(Self.unstaged) ?? []
        let staged = status.map(Self.staged) ?? []
        // The panel's height is always used: a card with files scrolls inside and shares the free height equally with
        // the other cards that have files; an empty card fits its text; the commit box stays at the bottom, or at the
        // top (`PrefKey.commitBoxPosition`).
        VStack(spacing: SectionCardMetrics.spacing) {
            if commitBoxOnTop { commitBox(staged: staged, unstaged: unstaged) }
            // During an operation the card stays once its files are resolved, saying nothing is left.
            if !conflicted.isEmpty || session.repoState?.isOperationInProgress == true {
                conflictedCard(conflicted)
            }
            UnstagedStagedCards { unstagedCard(unstaged) } staged: { stagedCard(staged) }
            if conflicted.isEmpty && unstaged.isEmpty && staged.isEmpty {
                Spacer(minLength: 0)
            }
            if !commitBoxOnTop { commitBox(staged: staged, unstaged: unstaged) }
        }
    }

    private var commitBoxOnTop: Bool { commitBoxPosition == "top" }

    private func commitBox(staged: [FileChange], unstaged: [FileChange]) -> some View {
        CommitBox(session: session, stagedCount: staged.count, changeCount: staged.count + unstaged.count,
                  busy: $busy, error: errorBinding(.commit))
    }

    // MARK: Cards

    /// The files git left with conflicts (a merge, rebase, cherry-pick, revert or stash pop): a click opens the conflict
    /// editor in panel2 (`FileTarget.isConflict`); the button stages the file as it is, marking it resolved.
    private func conflictedCard(_ files: [FileChange]) -> some View {
        SectionCard("Conflicted", systemImage: "exclamationmark.triangle", count: files.count, contentPadding: 6,
                    tone: Palette.conflictTone) {
            if files.isEmpty {
                EmptyFilesText(text: "No conflicts left")
            } else {
                FilesScroll {
                    FileListView(files: files, repoURL: session.url, card: .conflicted) { file in
                        rowButton("checkmark.circle", help: "Mark as Resolved (Stage File)", busy: .stage(file.path)) {
                            run(.stage([file.path]), busy: .stage(file.path), part: .conflicted)
                        }
                    }
                    .fileMenu { file in
                        [menuAction("Mark as Resolved (Stage File)", busy: [.stage(file.path)]) {
                            run(.stage([file.path]), busy: .stage(file.path), part: .conflicted)
                        }] + fileTools(file)
                    }
                    .folderButtons { _, files in
                        rowButton("checkmark.circle", help: "Mark Folder as Resolved (Stage Files)",
                                  busy: files.map { .stage($0.path) }) { stage(files, part: .conflicted) }
                    }
                    .folderMenu { _, files in
                        [menuAction("Mark Folder as Resolved (Stage Files)", busy: files.map { .stage($0.path) }) {
                            stage(files, part: .conflicted)
                        }]
                    }
                    .onSelectFile(selected: openWIPPath) { file in
                        session.selectFile(FileTarget(source: .wip, file: file))
                    }
                }
            }
            ErrorText(message: errors[.conflicted])
        } accessory: {
            FileListModeToggle(card: .conflicted)
        }
    }

    private func unstagedCard(_ files: [FileChange]) -> some View {
        SectionCard("Unstaged", systemImage: "doc.badge.ellipsis", count: files.count, contentPadding: 6) {
            if files.isEmpty {
                EmptyFilesText(text: "No unstaged changes")
            } else {
                FilesScroll {
                    FileListView(files: files, repoURL: session.url, card: .unstaged) { file in
                        HStack(spacing: 10) {
                            rowButton("arrow.uturn.backward",
                                      help: file.kind == .untracked ? "Delete File…" : "Discard Changes…",
                                      busy: .discard(file.path)) { confirmDiscard(file) }
                            rowButton("plus.circle", help: "Stage File", busy: .stage(file.path)) {
                                run(.stage([file.path]), busy: .stage(file.path), part: .unstaged)
                            }
                        }
                    }
                    .fileSizes(sizes)
                    .folderButtons { folder, files in
                        HStack(spacing: 10) {
                            rowButton("arrow.uturn.backward", help: "Discard Changes in Folder…",
                                      busy: files.map { .discard($0.path) }) { confirmDiscard(folder: folder, files) }
                            rowButton("plus.circle", help: "Stage Folder", busy: files.map { .stage($0.path) }) {
                                stage(files, part: .unstaged)
                            }
                        }
                    }
                    .fileMenu { file in
                        [
                            menuAction("Stage File", busy: [.stage(file.path)]) {
                                run(.stage([file.path]), busy: .stage(file.path), part: .unstaged)
                            },
                            menuAction(file.kind == .untracked ? "Delete File…" : "Discard Changes…",
                                       busy: [.discard(file.path)], destructive: true) { confirmDiscard(file) },
                        ] + wipExtras(file) + fileTools(file)
                    }
                    .folderMenu { folder, files in
                        [
                            menuAction("Stage Folder", busy: files.map { .stage($0.path) }) {
                                stage(files, part: .unstaged)
                            },
                            menuAction("Discard Changes in Folder…", busy: files.map { .discard($0.path) },
                                       destructive: true) { confirmDiscard(folder: folder, files) },
                        ] + wipExtras(folder: folder, files)
                    }
                    .onSelectFile(selected: openWIPPath) { file in
                        session.selectFile(FileTarget(source: .wip, file: file))
                    }
                }
            }
            ErrorText(message: errors[.unstaged])
        } accessory: {
            HStack(spacing: 10) {
                FileListModeToggle(card: .unstaged)
                headerButton("Stage All", busy: .stageAll, disabled: files.isEmpty, fill: Palette.stageAllFill) {
                    run(.stageAll, busy: .stageAll, part: .unstaged)
                }
            }
        }
        // Off: no sizes and nothing read from disk (-1 never matches a read count, so turning it on reads again).
        .task(id: showsSizes ? session.statusReads : -1) {
            sizes = showsSizes ? await Self.sizes(of: files, in: session.url) : [:]
        }
    }

    private func stagedCard(_ files: [FileChange]) -> some View {
        SectionCard("Staged", systemImage: "tray.full", count: files.count, contentPadding: 6) {
            if files.isEmpty {
                EmptyFilesText(text: "No staged changes")
            } else {
                FilesScroll {
                    FileListView(files: files, repoURL: session.url, card: .staged) { file in
                        rowButton("minus.circle", help: "Unstage File", busy: .unstage(file.path)) {
                            run(.unstage(Self.unstagePaths(file)), busy: .unstage(file.path), part: .staged)
                        }
                    }
                    .fileMenu { file in
                        [menuAction("Unstage File", busy: [.unstage(file.path)]) {
                            run([.unstage(Self.unstagePaths(file))], busy: [.unstage(file.path)], part: .staged)
                        }] + wipExtras(file) + fileTools(file)
                    }
                    .folderButtons { _, files in
                        rowButton("minus.circle", help: "Unstage Folder", busy: files.map { .unstage($0.path) }) {
                            unstage(files)
                        }
                    }
                    .folderMenu { folder, files in
                        [menuAction("Unstage Folder", busy: files.map { .unstage($0.path) }) { unstage(files) }]
                            + wipExtras(folder: folder, files)
                    }
                    .onSelectFile(selected: openWIPPath) { file in
                        session.selectFile(FileTarget(source: .wip, file: file))
                    }
                }
            }
            ErrorText(message: errors[.staged])
        } accessory: {
            HStack(spacing: 10) {
                FileListModeToggle(card: .staged)
                headerButton("Unstage All", busy: .unstageAll, disabled: files.isEmpty,
                             fill: Palette.unstageAllFill) {
                    run(.unstageAll, busy: .unstageAll, part: .staged)
                }
            }
        }
    }

    /// A row's icon button; a small spinner in its place while its write runs.
    private func rowButton(_ systemImage: String, help: String, busy key: Busy, action: @escaping () -> Void)
        -> some View
    {
        rowButton(systemImage, help: help, busy: [key], action: action)
    }

    /// A row's icon button for several files (a folder's); a spinner while one of `keys` runs.
    private func rowButton(_ systemImage: String, help: String, busy keys: [Busy], action: @escaping () -> Void)
        -> some View
    {
        ZStack {
            if keys.contains(where: busy.contains) {
                ProgressView().controlSize(.mini)
            } else {
                Button(action: action) {
                    Image(systemName: systemImage)
                        .foregroundStyle(.secondary)
                }
                .buttonStyle(RowIconButtonStyle())
                .help(help)
                .accessibilityLabel(help)
            }
        }
        .frame(width: 16, height: 16)
    }

    private func headerButton(_ title: String, busy key: Busy, disabled: Bool, fill: Color,
                              action: @escaping () -> Void) -> some View
    {
        Button(action: action) {
            HStack(spacing: 4) {
                if busy.contains(key) { ProgressView().controlSize(.mini) }
                Text(title)
            }
        }
        .buttonStyle(RowTextButtonStyle(fill: fill))
        .disabled(disabled || busy.contains(key))
    }

    /// The WIP file whose diff or blame panel2 shows, drawn as selected in both lists.
    private var openWIPPath: String? {
        session.openFile?.source == .wip ? session.openFile?.path : session.blamePath(in: .wip)
    }

    // MARK: Writes

    /// Shows `key` busy now (the click's frame), then runs the write; its error goes to `part`'s card.
    private func run(_ write: RepoSession.Write, busy key: Busy, part: Part) {
        run([write], busy: [key], part: part)
    }

    /// Shows `keys` busy now, then runs the writes in order (stopping at the first error, which goes to `part`'s card).
    private func run(_ writes: [RepoSession.Write], busy keys: [Busy], part: Part) {
        busy.formUnion(keys)
        errors[part] = nil
        Task {
            do {
                for write in writes { try await session.perform(write) }
            } catch {
                errors[part] = RepoSession.writeMessage(for: error)
            }
            busy.subtract(keys)
        }
    }

    /// A context menu entry doing what a row's button does; disabled while one of `keys` runs.
    private func menuAction(_ title: String, busy keys: [Busy], destructive: Bool = false,
                            _ perform: @escaping @MainActor () -> Void) -> MenuEntry
    {
        .action(title, enabled: !keys.contains(where: busy.contains), destructive: destructive, perform)
    }

    /// File History (to HEAD) and Blame (of the working tree) after a separator; none for an untracked file (no
    /// history, nothing to blame), no Blame for a deleted one.
    private func fileTools(_ file: FileChange) -> [MenuEntry] {
        guard file.kind != .untracked else { return [] }
        return [.separator]
            + RepoMenus.fileTools(path: file.path, rev: nil, blame: file.kind != .deleted, session: session)
    }

    /// `RepoMenus.wipExtras` of a file row (not the conflicted card's: git cannot stash with unmerged files).
    private func wipExtras(_ file: FileChange) -> [MenuEntry] {
        RepoMenus.wipExtras(file, untracked: file.kind == .untracked, session: session)
    }

    /// `RepoMenus.wipExtras` of a folder row, for every change under `folder`.
    private func wipExtras(folder: String, _ files: [FileChange]) -> [MenuEntry] {
        RepoMenus.wipExtras(FileChange(kind: .modified, path: folder),
                            untracked: files.allSatisfy { $0.kind == .untracked }, isFolder: true, session: session)
    }

    /// Stages `files` (a folder's), each showing busy.
    private func stage(_ files: [FileChange], part: Part) {
        run([.stage(files.map(\.path))], busy: files.map { .stage($0.path) }, part: part)
    }

    /// Unstages `files` (a folder's), each showing busy.
    private func unstage(_ files: [FileChange]) {
        run([.unstage(files.flatMap(Self.unstagePaths))], busy: files.map { .unstage($0.path) }, part: .staged)
    }

    /// A rename's old path too, or its deletion stays staged.
    private static func unstagePaths(_ file: FileChange) -> [String] {
        [file.originalPath, file.path].compactMap { $0 }
    }

    /// Asks, then discards the tracked files under `folder` and deletes its untracked ones.
    private func confirmDiscard(folder: String, _ files: [FileChange]) {
        let untracked = files.filter { $0.kind == .untracked }.map(\.path)
        let tracked = files.filter { $0.kind != .untracked }.map(\.path)
        let count = files.count == 1 ? "1 file" : "\(files.count) files"
        let message = (untracked.isEmpty ? "" : "Its untracked files are deleted. ") + "This cannot be undone."
        model.presentModal(.confirmation(ModalConfirmation(
            title: "Discard the changes to \(count) in \((folder as NSString).lastPathComponent)?", message: message,
            button: "Discard", isDestructive: true) {
            let writes: [RepoSession.Write] = (tracked.isEmpty ? [] : [.discard(tracked)])
                + (untracked.isEmpty ? [] : [.removeUntracked(untracked)])
            run(writes, busy: files.map { .discard($0.path) }, part: .unstaged)
        }))
    }

    private func discard(_ file: FileChange) {
        let write: RepoSession.Write = file.kind == .untracked ? .removeUntracked([file.path]) : .discard([file.path])
        run(write, busy: .discard(file.path), part: .unstaged)
    }

    private func confirmDiscard(_ file: FileChange) {
        model.presentModal(.confirmation(ModalConfirmation(
            title: Self.discardTitle(file), message: "This cannot be undone.",
            button: file.kind == .untracked ? "Delete" : "Discard", isDestructive: true) { discard(file) }))
    }

    private func errorBinding(_ part: Part) -> Binding<String?> {
        Binding { errors[part] } set: { errors[part] = $0 }
    }

    private static func discardTitle(_ file: FileChange) -> String {
        file.kind == .untracked ? "Delete \(file.name)?" : "Discard the changes to \(file.name)?"
    }

    // MARK: Files

    /// The size on disk of each of `files`; none for a deleted file or a folder (a submodule).
    private static func sizes(of files: [FileChange], in root: URL) async -> [String: Int64] {
        await Task.detached(priority: .utility) {
            var sizes: [String: Int64] = [:]
            for file in files where file.kind != .deleted {
                let path = root.appending(path: file.path, directoryHint: .notDirectory).path
                guard let attributes = try? FileManager.default.attributesOfItem(atPath: path),
                      attributes[.type] as? FileAttributeType != .typeDirectory,
                      let size = attributes[.size] as? NSNumber else { continue }
                sizes[file.path] = size.int64Value
            }
            return sizes
        }.value
    }

    /// Paths with unmerged index entries, in status order.
    fileprivate static func conflicted(_ status: WorkingStatus) -> [FileChange] {
        status.conflicted.map { FileChange(kind: .conflicted, path: $0.path) }
    }

    /// Changes in the working tree and untracked files (conflicts have their own card).
    fileprivate static func unstaged(_ status: WorkingStatus) -> [FileChange] {
        status.entries.compactMap { entry in
            switch entry.kind {
            case .untracked: FileChange(kind: .untracked, path: entry.path)
            case .unmerged, .ignored: nil
            default: entry.isUnstaged ? FileChange(letter: entry.worktree.rawValue, path: entry.path) : nil
            }
        }
    }

    fileprivate static func staged(_ status: WorkingStatus) -> [FileChange] {
        status.entries.compactMap { entry in
            entry.isStaged
                ? FileChange(letter: entry.index.rawValue, path: entry.path, originalPath: entry.originalPath) : nil
        }
    }
}

/// Another worktree's changes (a click on its graph or sidebar row), read-only: its folder, then its conflicted,
/// unstaged and staged files as its own tab lists them. Staging, discarding, committing and file diffs are its tab's.
struct WorktreeChangesPanel: View {
    let path: String
    let status: WorkingStatus

    var body: some View {
        let folder = URL(filePath: path, directoryHint: .isDirectory)
        let conflicted = WIPPanel.conflicted(status)
        let unstaged = WIPPanel.unstaged(status)
        let staged = WIPPanel.staged(status)
        VStack(spacing: SectionCardMetrics.spacing) {
            WorktreeHeaderCard(path: path, branch: status.branch.name)
            if !conflicted.isEmpty {
                filesCard("Conflicted", systemImage: "exclamationmark.triangle", conflicted, empty: "", folder: folder,
                          card: .conflicted, tone: Palette.conflictTone)
            }
            UnstagedStagedCards {
                filesCard("Unstaged", systemImage: "doc.badge.ellipsis", unstaged, empty: "No unstaged changes",
                          folder: folder, card: .unstaged)
            } staged: {
                filesCard("Staged", systemImage: "tray.full", staged, empty: "No staged changes", folder: folder,
                          card: .staged)
            }
            if conflicted.isEmpty && unstaged.isEmpty && staged.isEmpty {
                Spacer(minLength: 0)
            }
        }
    }

    private func filesCard(_ title: String, systemImage: String, _ files: [FileChange], empty: String, folder: URL,
                           card: FileListCard, tone: Color? = nil)
        -> some View
    {
        SectionCard(title, systemImage: systemImage, count: files.count, contentPadding: 6, tone: tone) {
            if files.isEmpty {
                EmptyFilesText(text: empty)
            } else {
                FilesScroll {
                    FileListView(files: files, repoURL: folder, card: card)
                }
            }
        } accessory: {
            FileListModeToggle(card: card)
        }
    }
}

/// The worktree whose changes `WorktreeChangesPanel` shows: its folder's name, its branch, its path.
private struct WorktreeHeaderCard: View {
    let path: String
    /// Nil while loading (the placeholder) or on a detached HEAD.
    let branch: String?

    var body: some View {
        SectionCard(URL(filePath: path).lastPathComponent, systemImage: "folder") {
            VStack(alignment: .leading, spacing: 4) {
                if let branch {
                    Label { Text(branch) } icon: { IconImage("lucide-git-branch") }
                }
                Text(ProfileLibrary.abbreviated(path))
                    .font(.settingsCaption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .truncationMode(.middle)
                    .textSelection(.enabled)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }
}

/// The skeleton of `WorktreeChangesPanel`: its folder card, then the Unstaged and Staged cards with capsule rows.
struct WorktreeChangesPlaceholder: View {
    let path: String

    var body: some View {
        VStack(spacing: SectionCardMetrics.spacing) {
            WorktreeHeaderCard(path: path, branch: nil)
            SkeletonUnstagedStagedCards()
        }
    }
}

/// The skeleton of the WIP panel: the same cards with capsule rows (the Conflicted card when the last status had
/// conflicts).
struct WIPPlaceholder: View {
    var hasConflicts = false
    @AppStorage(PrefKey.commitBoxPosition.rawValue, store: Preferences.defaults)
    private var commitBoxPosition = "bottom"

    var body: some View {
        // The loaded panel's shape: the file cards share the height (no scroll views here, the placeholder stays
        // cheap in the click's frame), the commit box at the bottom or the top.
        VStack(spacing: SectionCardMetrics.spacing) {
            if commitBoxPosition == "top" { commitBox }
            if hasConflicts {
                SectionCard("Conflicted", systemImage: "exclamationmark.triangle", countIsLoading: true, contentPadding: 6,
                            tone: Palette.conflictTone) {
                    SkeletonFileRows(fractions: [0.45, 0.6])
                        .frame(maxHeight: .infinity, alignment: .top)
                }
            }
            SkeletonUnstagedStagedCards()
            if commitBoxPosition != "top" { commitBox }
        }
    }

    private var commitBox: some View {
        SectionCard("Commit", systemImage: "checkmark.circle") {
            VStack(alignment: .leading, spacing: 10) {
                SkeletonLine(fraction: 1, height: 28)
                SkeletonLine(fraction: 1, height: 64)
                HStack {
                    SkeletonLine(width: 80, height: 14)
                    Spacer()
                    SkeletonLine(width: 120, height: 24)
                }
            }
        }
    }
}

/// The placeholders' Unstaged and Staged cards with capsule rows, in `UnstagedStagedCards`' order.
private struct SkeletonUnstagedStagedCards: View {
    var body: some View {
        UnstagedStagedCards {
            SectionCard("Unstaged", systemImage: "doc.badge.ellipsis", countIsLoading: true, contentPadding: 6) {
                SkeletonFileRows(fractions: [0.55, 0.4, 0.65, 0.5])
                    .frame(maxHeight: .infinity, alignment: .top)
            }
        } staged: {
            SectionCard("Staged", systemImage: "tray.full", countIsLoading: true, contentPadding: 6) {
                SkeletonFileRows(fractions: [0.5, 0.35])
                    .frame(maxHeight: .infinity, alignment: .top)
            }
        }
    }
}

/// The Unstaged and Staged cards in `PrefKey.stagedPosition`'s order, as two children of the caller's stack (so they
/// share its height and spacing like the other cards).
private struct UnstagedStagedCards<Unstaged: View, Staged: View>: View {
    @ViewBuilder let unstaged: () -> Unstaged
    @ViewBuilder let staged: () -> Staged
    @AppStorage(PrefKey.stagedPosition.rawValue, store: Preferences.defaults) private var stagedPosition = "below"

    var body: some View {
        if stagedPosition == "above" {
            staged()
            unstaged()
        } else {
            unstaged()
            staged()
        }
    }
}

// MARK: - Commit box

private struct CommitBox: View {
    let session: RepoSession
    let stagedCount: Int
    /// Staged and unstaged files: Explain needs at least one.
    let changeCount: Int
    @Binding var busy: Set<WIPPanel.Busy>
    @Binding var error: String?

    static let summaryLimit = 72

    var body: some View {
        @Bindable var session = session
        let draft = session.commitDraft
        let count = draft.summary.count
        SectionCard("Commit", systemImage: "checkmark.circle") {
            VStack(alignment: .leading, spacing: 8) {
                HStack(spacing: 8) {
                    TextField("Summary", text: $session.commitDraft.summary)
                        .textFieldStyle(.settings)
                    Text("\(count)/\(Self.summaryLimit)")
                        .font(.settingsCaption)
                        .monospacedDigit()
                        .foregroundStyle(count > Self.summaryLimit ? Color(nsColor: Palette.graphLanes[6]) : .secondary)
                        .help("Keep the summary within \(Self.summaryLimit) characters")
                }
                TextEditor(text: $session.commitDraft.description)
                    .font(.body)
                    .settingsTextEditor()
                    .frame(height: 72)
                    .overlay(alignment: .topLeading) {
                        if draft.description.isEmpty {
                            Text("Description")
                                .foregroundStyle(.tertiary)
                                .padding(.horizontal, 11)
                                .padding(.vertical, 8)
                                .allowsHitTesting(false)
                        }
                    }
                HStack(spacing: 8) {
                    Toggle("Amend", isOn: amendBinding)
                        .toggleStyle(CompactSwitch())
                        .disabled(busy.contains(.commit))
                    Text("Amend")
                        .foregroundStyle(.secondary)
                    if busy.contains(.amendMessage) { ProgressView().controlSize(.mini) }
                    Spacer(minLength: 8)
                    Button(action: commit) {
                        HStack(spacing: 6) {
                            if busy.contains(.commit) { ProgressView().controlSize(.mini) }
                            Text(draft.amend ? "Amend Commit" : commitTitle)
                        }
                    }
                    .buttonStyle(RowTextButtonStyle(formRow: true, prominent: true))
                    .keyboardShortcut(.return, modifiers: .command)
                    .disabled(!canCommit)
                    .help("Commit (⌘↩)")
                }
                ErrorText(message: error)
            }
            .padding(.top, SectionCardMetrics.accessoryGap)
        } accessory: {
            // AI (task 12.3): each opens the result card; nothing is sent before the click.
            HStack(spacing: 6) {
                AIHookButton(title: "Explain", help: "Explain the uncommitted changes with AI",
                             unavailable: changeCount == 0 ? "No changes to explain" : nil, seam: "explain-wip",
                             small: true) {
                    session.startAI(.explainWorkingChanges)
                }
                AIHookButton(title: "Generate Message", systemImage: "sparkles",
                             help: "Write a commit message for the staged changes with AI",
                             unavailable: generateUnavailable, seam: "generate", small: true) {
                    let summaryOnly = Preferences.defaults.bool(forKey: PrefKey.aiCommitSummaryOnly.rawValue)
                    session.startAI(.commitMessage(summaryOnly: summaryOnly, amend: session.commitDraft.amend,
                                                   currentMessage: message))
                }
            }
        }
        #if DEBUG
        .task {
            // `-HistqAI generate,amend`: Amend on as the toggle does, so the last message loads before the click.
            guard AIStub.seamHook == "generate", AIStub.seamOptions.contains("amend"), !session.commitDraft.amend
            else { return }
            AIStub.log("amend on")
            amendBinding.wrappedValue = true
        }
        #endif
    }

    /// Why Generate Message cannot run: nothing staged (Amend covers the last commit), or the amended message still
    /// loading, so a click never takes a stale one.
    private var generateUnavailable: String? {
        let draft = session.commitDraft
        if busy.contains(.amendMessage) { return "Loading the last commit message" }
        if stagedCount == 0 && !draft.amend { return "Stage changes first" }
        #if DEBUG
        // `-HistqAI generate[,amend]`: the seam clicks once the branch is read and, with `amend`, the message is in.
        if AIStub.seamHook == "generate" {
            if session.refs.value == nil { return "Reading the branches" }
            if AIStub.seamOptions.contains("amend") && !draft.amend { return "Turning Amend on" }
        }
        #endif
        return nil
    }

    private var commitTitle: String {
        stagedCount == 1 ? "Commit 1 File" : "Commit \(stagedCount) Files"
    }

    private var canCommit: Bool {
        let draft = session.commitDraft
        let hasSummary = !draft.summary.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        return hasSummary && (draft.amend || stagedCount > 0) && !busy.contains(.commit)
            && !busy.contains(.amendMessage)
    }

    /// The summary, a blank line and the description (when there is one).
    private var message: String {
        let draft = session.commitDraft
        let summary = draft.summary.trimmingCharacters(in: .whitespacesAndNewlines)
        let description = draft.description.trimmingCharacters(in: .whitespacesAndNewlines)
        return description.isEmpty ? summary : summary + "\n\n" + description
    }

    /// On: keeps what was typed and loads HEAD's message into the fields. Off: puts the typed text back.
    private var amendBinding: Binding<Bool> {
        Binding { session.commitDraft.amend } set: { isOn in
            guard isOn != session.commitDraft.amend else { return }
            session.commitDraft.amend = isOn
            if isOn {
                session.commitDraft.savedSummary = session.commitDraft.summary
                session.commitDraft.savedDescription = session.commitDraft.description
                loadLastMessage()
            } else {
                busy.remove(.amendMessage)
                session.commitDraft.summary = session.commitDraft.savedSummary
                session.commitDraft.description = session.commitDraft.savedDescription
            }
        }
    }

    private func loadLastMessage() {
        busy.insert(.amendMessage)
        error = nil
        Task {
            do {
                let (subject, body) = try await session.lastCommitMessage()
                if session.commitDraft.amend, busy.contains(.amendMessage) {
                    session.commitDraft.summary = subject
                    session.commitDraft.description = body
                }
            } catch {
                self.error = RepoSession.writeMessage(for: error)
            }
            busy.remove(.amendMessage)
        }
    }

    private func commit() {
        guard canCommit else { return }
        let write: RepoSession.Write = session.commitDraft.amend ? .amend(message: message) : .commit(message: message)
        let title = session.commitDraft.amend ? "Amend" : "Commit"
        busy.insert(.commit)
        error = nil
        Task {
            do {
                try await session.perform(write)
                session.commitDraft = CommitDraft()
                session.postToast(.success(title))
            } catch {
                // Only in its toast, not in the card too.
                session.report(OperationFailure(title: title, write: write, error: error,
                                                message: RepoSession.writeMessage(for: error)))
            }
            busy.remove(.commit)
        }
    }
}

// MARK: - Small parts

/// A files card's rows in their own scroll view, so the card takes its share of the panel's height and scrolls inside
/// instead of the whole panel scrolling.
private struct FilesScroll<Content: View>: View {
    @ViewBuilder let content: () -> Content

    var body: some View {
        CardScrollView {
            content()
        }
        .frame(maxHeight: .infinity)
    }
}

private struct EmptyFilesText: View {
    let text: String

    var body: some View {
        Text(text)
            .foregroundStyle(.secondary)
            .padding(.horizontal, 6)
            .frame(height: FileListView<EmptyView>.rowHeight)
    }
}

/// A write's error under a card's content; nothing when nil.
struct ErrorText: View {
    let message: String?

    var body: some View {
        if let message {
            Label(message, systemImage: "exclamationmark.triangle.fill")
                .font(.settingsCaption)
                .foregroundStyle(Color(nsColor: Palette.graphLanes[6]))
                .fixedSize(horizontal: false, vertical: true)
                .textSelection(.enabled)
                .padding(.top, 4)
        }
    }
}
