// A commit or a stash in the detail panel, its parts in cards: the commit info (subject, body, author and
// committer with their avatars, date, sha with a copy button, parents that jump to their row, and the AI button
// Explain), then its files.
import AppKit
import Combine
import HistqCore
import SwiftUI

struct CommitDetailPanel: View {
    let session: RepoSession
    let commit: CommitDetail
    /// The select this detail answers and its timing detail, passed in (not read from `session`): a view kept for its
    /// removal must not log the next select's lines.
    let token: Int
    let timingDetail: String
    @AppStorage(PrefKey.commitShowsAllFiles.rawValue, store: Preferences.defaults) private var showsAll = false
    @Environment(\.textSize) private var textSize
    /// Every file of a commit's tree ("View all files"), read while the switch is on; kept for its commit only.
    @State private var allFiles: AllFiles?

    private struct AllFiles {
        let hash: String
        let files: [FileChange]
    }

    /// What the all-files read depends on: a new commit, the switch, or the commit's own files arriving.
    private struct AllFilesKey: Equatable {
        let hash: String
        let showsAll: Bool
        let filesLoaded: Bool
    }

    var body: some View {
        // The cards fill the panel: the info card as tall as its content up to `infoFraction` of the panel (its
        // message then scrolls inside), the Files card the rest (its list scrolls inside). A header whose files still
        // load has the same info card, so the Files card does not move when they arrive.
        GeometryReader { proxy in
            VStack(spacing: SectionCardMetrics.spacing) {
                CommitInfoCard(session: session, commit: commit, token: token, timingDetail: timingDetail,
                               maxHeight: proxy.size.height * CommitDetailMetrics.infoFraction)
                    .layoutPriority(1)
                CommitFilesCard(count: commit.files?.count, token: token, detail: timingDetail,
                                state: commit.files == nil ? "pending" : "loaded") { query in
                    files(matching: query)
                }
            }
        }
        .task(id: AllFilesKey(hash: commit.hash, showsAll: showsAll, filesLoaded: commit.files != nil)) {
            guard showsAll, commit.files != nil, allFiles?.hash != commit.hash else { return }
            let commit = commit
            // A failed read falls back to the changed files, so the card never stays a skeleton.
            let files = (try? await session.readAllFiles(of: commit)) ?? commit.files ?? []
            guard !Task.isCancelled else { return }
            allFiles = AllFiles(hash: commit.hash, files: files)
        }
    }

    /// The rows the card lists: the changed files, or every file of the tree with "View all files" on; nil while
    /// either is still being read.
    private var shownFiles: [FileChange]? {
        guard showsAll, commit.files != nil else { return commit.files }
        return allFiles?.hash == commit.hash ? allFiles?.files : nil
    }

    /// The card's body: the shown files that `query` matches (all with an empty query).
    @ViewBuilder private func files(matching query: String) -> some View {
        if let shown = shownFiles {
            let files = FileSearch.filter(shown, query: query)
            if files.isEmpty {
                Text(shown.isEmpty ? "No file changes" : "No matching files")
                    .font(textSize.body)
                    .foregroundStyle(.secondary)
                    .padding(.horizontal, 6)
                    .frame(height: FileListView<EmptyView>.rowHeight(textSize))
            } else {
                CardScrollView {
                    FileListView(files: files, repoURL: session.url, card: .commit)
                        .fileMenu { [session, commit] file in
                            // A stash's file is applied, not checked out.
                            guard !commit.isStash else {
                                return RepoMenus.stashFile(file, stash: commit.hash, session: session)
                            }
                            // A merge commit has no single patch; a file it did not change has none either.
                            let patch = commit.parents.count > 1 || file.kind == .unchanged ? []
                                : RepoMenus.filePatch(path: file.path, originalPath: file.originalPath,
                                                      source: .commit(commit.hash), session: session)
                            return RepoMenus.checkoutFile(file, commit: commit.hash, session: session) + patch
                        }
                        .onSelectFile(selected: openPath) { [session, commit] file in
                            session.selectFile(FileTarget(source: .commit(commit.hash), file: file))
                        }
                }
                // Each commit's list starts at its top.
                .id(commit.hash)
            }
        } else if commit.files != nil {
            // Every file of the tree still loading: skeleton rows only when the read takes over 150 ms.
            DelayedReveal(token: commit.hash, detail: "\(timingDetail) all-files") {
                SkeletonFileRows(fractions: [0.6, 0.45, 0.7, 0.5])
            }
        } else {
            // Files still loading: an empty body, skeleton rows only when the read takes over 150 ms.
            DelayedReveal(token: token, detail: timingDetail, isCurrent: { [session, token] in
                session.selectToken == token && session.detail.value?.isReady == false
            }) {
                SkeletonFileRows(fractions: [0.6, 0.45, 0.7, 0.5])
            }
        }
    }

    /// This commit's file whose diff or blame panel2 shows, drawn as selected.
    private var openPath: String? {
        session.openFile?.source == .commit(commit.hash) ? session.openFile?.path
            : session.blamePath(in: .commit(commit.hash))
    }
}

private enum CommitDetailMetrics {
    /// The info card's share of the panel's height at most; a longer message scrolls inside the card.
    static let infoFraction: CGFloat = 0.4
    /// The message's height at least (about two subject lines and its box's padding), even when the card's other
    /// rows alone pass `infoFraction` (a small window).
    static let messageMinHeight: CGFloat = 44 + 2 * messagePadding
    /// The padding inside the message's box.
    static let messagePadding: CGFloat = 10
    /// The inline message editor's height at least (summary, description, the pushed note and the buttons), so it is
    /// never cut in a small window.
    static let editorMinHeight: CGFloat = 220
}

/// The box that sets the commit message (subject and body) apart from the card's other rows: a faint fill, a 1 pt
/// edge, padding around.
private struct MessageBox: ViewModifier {
    func body(content: Content) -> some View {
        let shape = RoundedRectangle(cornerRadius: 10, style: .continuous)
        content
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(CommitDetailMetrics.messagePadding)
            .background(shape.fill(Palette.tabFill))
            .overlay(shape.strokeBorder(Palette.surfaceBorder, lineWidth: 1))
    }
}

/// The commit detail's Files card (a compare's too), loaded or not: the count (a skeleton while nil), the search,
/// all-files and paths/tree buttons, and a body that takes the panel's height left under the info card. The search
/// button opens a field at the body's top, and `content` gets its query (empty while closed). Logs its edges
/// (`FilesLayoutLog`) as `state`.
struct CommitFilesCard<Content: View>: View {
    let count: Int?
    let token: Int
    let detail: String
    /// `placeholder`, `pending` (a header from the log, files loading) or `loaded`.
    let state: String
    /// False leaves the all-files button out (a compare has no single tree).
    var allFilesButton = true
    var title = "Files"
    @ViewBuilder let content: (_ query: String) -> Content
    @State private var isSearching = false
    @State private var query = ""
    @FocusState private var searchFocused: Bool

    var body: some View {
        SectionCard(title, systemImage: "doc.on.doc", count: count, countIsLoading: count == nil, contentPadding: 6) {
            // One stack: a frame on a list of views (skeleton rows) would apply to each row.
            VStack(alignment: .leading, spacing: 0) {
                if isSearching {
                    TextField("Search files", text: $query, prompt: Text("Search files"))
                        .textFieldStyle(.settings)
                        .labelsHidden()
                        .focused($searchFocused)
                        // Next run-loop turn, once the field is in the window.
                        .onAppear { DispatchQueue.main.async { searchFocused = true } }
                        .onKeyPress(.escape) {
                            setSearching(false)
                            return .handled
                        }
                        .padding(.bottom, 6)
                }
                content(isSearching ? query : "")
            }
            .frame(maxHeight: .infinity, alignment: .top)
        } accessory: {
            HStack(spacing: 10) {
                Button {
                    setSearching(!isSearching)
                } label: {
                    Image(systemName: "magnifyingglass")
                        .foregroundStyle(isSearching ? AnyShapeStyle(Color.accentColor) : AnyShapeStyle(.secondary))
                }
                .buttonStyle(RowIconButtonStyle())
                .help(isSearching ? "Close Search" : "Search Files")
                .accessibilityLabel(isSearching ? "Close search" : "Search files")
                if allFilesButton { AllFilesToggle() }
                FileListModeToggle(card: .commit)
            }
        }
        .modifier(FilesLayoutLog(token: token, detail: detail, state: state))
    }

    /// Opens the field (it takes the focus as it appears), or closes it and clears the query.
    private func setSearching(_ on: Bool) {
        isSearching = on
        if !on { query = "" }
    }
}

/// The skeleton of the commit detail, in the loaded cards' frames: the info card's lines, then the Files card
/// filling the rest with its rows.
struct CommitDetailPlaceholder: View {
    /// The select it stands in for and its timing detail (`FilesLayoutLog`).
    let token: Int
    let detail: String

    var body: some View {
        VStack(spacing: SectionCardMetrics.spacing) {
            SectionCard("Commit", systemImage: "smallcircle.filled.circle") {
                // The loaded rows' fonts and spacing (subject, author, sha, parent), so a one-line message's card has
                // the loaded card's height.
                VStack(alignment: .leading, spacing: 10) {
                    line(.body, fraction: 0.75, height: 11)
                        .modifier(MessageBox())
                    HStack(spacing: 8) {
                        SkeletonLine(width: InfoMetrics.avatar, height: InfoMetrics.avatar)
                        VStack(alignment: .leading, spacing: 2) {
                            line(.body.weight(.medium), fraction: 0.45, height: 11)
                            line(.settingsCaption, fraction: 0.6, height: 9)
                        }
                    }
                    line(.body.monospaced(), fraction: 0.7, height: 11)
                    // A parent is a `RowTextButtonStyle` button: a callout label, 4 pt above and below.
                    line(.callout.weight(.medium), fraction: 0.35, height: 11)
                        .padding(.vertical, 4)
                }
            } accessory: {
                SkeletonLine(width: 64, height: 14)
            }
            CommitFilesCard(count: nil, token: token, detail: detail, state: "placeholder") { _ in
                SkeletonFileRows(fractions: [0.6, 0.45, 0.7, 0.5])
            }
        }
    }

    /// A skeleton bar as tall as a line of `font`.
    private func line(_ font: Font, fraction: CGFloat, height: CGFloat) -> some View {
        Text(verbatim: "M")
            .font(font)
            .hidden()
            .frame(maxWidth: .infinity, alignment: .leading)
            .overlay(alignment: .leading) {
                SkeletonLine(fraction: fraction, height: height)
            }
    }
}

/// DEBUG timing of the Files card's place, state-dir runs only: logs `layout <detail> <state> filesTop=<y>
/// filesBottom=<y> panelBottom=<y>`, its edges and the panel's height in the detail panel's coordinate space, for each
/// select, each state and whenever they move.
struct FilesLayoutLog: ViewModifier {
    /// The detail panel's coordinate space (`DetailPanel`).
    static let coordinateSpace = "detail-panel"
    let token: Int
    let detail: String
    /// `placeholder`, `pending` or `loaded`.
    let state: String

    private struct Edges: Equatable, Sendable {
        let token: Int
        let state: String
        let top: Double
        let bottom: Double
        let panel: Double
    }

    func body(content: Content) -> some View {
        #if DEBUG
        if AppState.isStateDirMode {
            let space = Self.coordinateSpace
            content.onGeometryChange(for: Edges.self) { [token, state] proxy in
                let frame = proxy.frame(in: .named(space))
                let panel = proxy.bounds(of: .named(space))?.height ?? -1
                // A tenth of a point: enough to see a shift, no noise from sub-pixel layout.
                let round = { (value: CGFloat) in Double((value * 10).rounded() / 10) }
                return Edges(token: token, state: state, top: round(frame.minY), bottom: round(frame.maxY),
                             panel: round(panel))
            } action: { [detail] edges in
                UITiming.layout("\(detail) \(edges.state) filesTop=\(edges.top) filesBottom=\(edges.bottom) "
                    + "panelBottom=\(edges.panel)")
            }
        } else {
            content
        }
        #else
        content
        #endif
    }
}

/// Several graph rows selected, in two cards: the rows (graph order), then the files of the diff they show together
/// (`RepoMenus.combinedDiff`), whose click opens a file's diff in panel2 as a compare's does. A selection with no such
/// diff gets a note in the files' place. With nil `files` and a diff it is the placeholder: the rows show at once, the
/// files as skeleton rows.
struct MultipleSelectionPanel: View {
    let session: RepoSession
    let items: [GraphItem]
    let diff: RepoSession.CombinedDiff?
    let files: [FileChange]?
    /// The select this detail answers and its timing detail (see `CommitDetailPanel`).
    let token: Int
    let timingDetail: String
    @Environment(\.textSize) private var textSize

    var body: some View {
        // With a diff, the rows card is as tall as its rows up to `rowsFraction` of the panel (then they scroll) and
        // the files card fills the rest; without one, the note fits its text and the rows card fills the rest.
        GeometryReader { proxy in
            VStack(spacing: SectionCardMetrics.spacing) {
                SelectedRowsCard(session: session, items: items,
                                 maxHeight: diff == nil ? nil : proxy.size.height * Self.rowsFraction)
                if let diff {
                    CommitFilesCard(count: files?.count, token: token, detail: timingDetail,
                                    state: files == nil ? "placeholder" : "loaded", allFilesButton: false,
                                    title: diff.isRange ? "Combined Changes" : "Differences") { query in
                        CompareFileList(session: session, base: diff.base, head: diff.head, files: files,
                                        query: query)
                    }
                } else {
                    SectionCard("Files", systemImage: "doc.on.doc") {
                        Text("The changes of this selection can't be shown together. Select commits that follow one "
                            + "another on one branch, or any two rows, to see their changes.")
                            .font(textSize.body)
                            .foregroundStyle(.secondary)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }
            }
        }
    }

    /// The rows card's share of the panel's height at most when the files card is under it.
    private static let rowsFraction: CGFloat = 0.45
}

/// The selected rows: avatar, subject, short sha, date and author for a commit; the WIP and stash rows too. Two rows
/// that `RepoMenus.comparePair` accepts get a Compare button; the Patch menu copies or saves the selected commits.
private struct SelectedRowsCard: View {
    let session: RepoSession
    let items: [GraphItem]
    /// The card's height at most: its rows scroll inside. Nil: the card fills the height left.
    let maxHeight: CGFloat?
    @Environment(\.textSize) private var textSize

    var body: some View {
        SectionCard("Commits", systemImage: "square.stack.3d.up", count: items.count, contentPadding: 6) {
            CardScrollView {
                // Lazy: a shift-click can select thousands of rows.
                LazyVStack(spacing: Self.rowSpacing) {
                    ForEach(items, id: \.self) { item in
                        SelectedRow(session: session, item: item, height: rowHeight)
                    }
                }
            }
            .frame(height: listHeight)
            .frame(maxHeight: maxHeight == nil ? .infinity : nil, alignment: .top)
        } accessory: {
            HStack(spacing: 10) {
                if let pair = RepoMenus.comparePair(session) {
                    Button("Compare") {
                        session.selectCompare(base: pair.base, head: pair.head)
                    }
                    .buttonStyle(RowTextButtonStyle())
                    .help(pair.head == nil ? "Compare the commit with the working tree" : "Compare the two commits")
                }
                patchMenu
            }
        }
    }

    /// Copy as Patch and Save as Patch of the selected commits, as one series; disabled with the reason when the
    /// selection has a merge commit, a stash or the WIP row.
    private var patchMenu: some View {
        let selection = RepoMenus.patchSelection(session)
        let target = PatchExport.commits(selection.commits)
        return Menu {
            Button("Copy as Patch") { session.copyPatch(target) }
            Button("Save as Patch…") { session.savePatch(target) }
        } label: {
            HStack(spacing: 4) {
                Text("Patch")
                MenuChevron()
            }
        }
        .menuStyle(.button)
        .buttonStyle(RowTextButtonStyle())
        .menuIndicator(.hidden)
        .fixedSize()
        .disabled(selection.reason != nil || selection.commits.isEmpty)
        .help(selection.reason ?? "Copy or save the selected commits as one patch")
        .accessibilityLabel("Patch of the selected commits")
    }

    private var rowHeight: CGFloat { textSize.scaled(44) }
    private static let rowSpacing: CGFloat = 4

    /// The rows' height, capped by `maxHeight` less the card's header and padding (two rows at least); nil (fill)
    /// without a cap.
    private var listHeight: CGFloat? {
        guard let maxHeight else { return nil }
        let rows = CGFloat(items.count) * (rowHeight + Self.rowSpacing) - Self.rowSpacing
        let room = maxHeight - SectionCardMetrics.headerHeight - 2 * SettingsMetrics.cardPadding
        return min(rows, max(room, 2 * rowHeight + Self.rowSpacing))
    }
}

/// One selected row: a commit from the log's header, the WIP row from the status, a stash from the log's stashes.
private struct SelectedRow: View {
    let session: RepoSession
    let item: GraphItem
    let height: CGFloat
    @AppStorage(PrefKey.dateFormat.rawValue, store: Preferences.defaults) private var dateFormat = "MM/dd/yy @ HH:mm"
    @Environment(\.textSize) private var textSize

    var body: some View {
        HStack(spacing: 8) {
            leading
                .frame(width: InfoMetrics.avatar, height: InfoMetrics.avatar)
            VStack(alignment: .leading, spacing: 2) {
                Text(info.title)
                    .font(textSize.body)
                    .lineLimit(1)
                    .truncationMode(.tail)
                Text(info.subtitle)
                    .font(textSize.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .truncationMode(.tail)
            }
            Spacer(minLength: 8)
            if let hash = info.hash {
                Text(hash.prefix(7))
                    .font(.callout.monospaced())
                    .foregroundStyle(.secondary)
            }
        }
        .padding(.horizontal, 8)
        .frame(height: height)
        .background(RoundedRectangle(cornerRadius: 8, style: .continuous).fill(Palette.tabFill))
        .help(info.title)
        .accessibilityElement(children: .combine)
    }

    @ViewBuilder private var leading: some View {
        switch item {
        case .commit:
            if let commit {
                AvatarImage(email: commit.authorEmail, name: commit.authorName, size: InfoMetrics.avatar)
                    .authorEmojiMenu(email: commit.authorEmail, name: commit.authorName, session)
            } else {
                symbol("smallcircle.filled.circle")
            }
        case .wip, .worktree: symbol("pencil")
        case .stash: symbol("archivebox")
        }
    }

    private func symbol(_ name: String) -> some View {
        Image(systemName: name)
            .foregroundStyle(.secondary)
            .accessibilityHidden(true)
    }

    private var commit: Commit? {
        guard case .commit(let hash) = item, let log = session.log.value, let index = log.commitIndex[hash],
              log.commits.indices.contains(index), log.commits[index].hash == hash
        else { return nil }
        return log.commits[index]
    }

    private var info: (title: String, subtitle: String, hash: String?) {
        switch item {
        case .commit(let hash):
            guard let commit else { return (String(hash.prefix(7)), "", hash) }
            return (commit.subject, "\(format(commit.authorDate)) by \(commit.authorName)", hash)
        case .wip:
            let count = session.status.value?.entries.count ?? 0
            return ("Working directory", count == 1 ? "1 file change" : "\(count) file changes", nil)
        case .stash(let hash):
            let stash = session.log.value?.stashes.first { $0.hash == hash }
            return (stash?.message ?? "Stash", stash.map { format($0.date) } ?? "", hash)
        case .worktree(let path):
            return (URL(filePath: path).lastPathComponent, path, nil)
        }
    }

    private func format(_ date: Date) -> String {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: Locale.current.identifier)
        formatter.dateFormat = dateFormat
        return formatter.string(from: date)
    }
}

// MARK: - Info

private struct CommitInfoCard: View {
    let session: RepoSession
    let commit: CommitDetail
    let token: Int
    let timingDetail: String
    /// The card's height at most: a longer message scrolls inside it.
    let maxHeight: CGFloat
    @AppStorage(PrefKey.dateFormat.rawValue, store: Preferences.defaults) private var dateFormat = "MM/dd/yy @ HH:mm"
    /// The inline message editor (HEAD only) is open, with its draft; `saving` while the edit runs.
    @State private var editing = false
    @State private var summary = ""
    @State private var description = ""
    @State private var saving = false
    @State private var copied = false
    @FocusState private var summaryFocused: Bool

    var body: some View {
        SectionCard(commit.isStash ? "Stash" : "Commit",
                    systemImage: commit.isStash ? "archivebox" : "smallcircle.filled.circle") {
            // The card's body, under its header and above its bottom padding: the message gets what the other rows
            // leave of the card's `maxHeight`.
            CappedMessageLayout(
                maxHeight: maxHeight - SectionCardMetrics.headerHeight - SectionCardMetrics.accessoryGap
                    - SettingsMetrics.cardPadding,
                minMessageHeight: editing ? CommitDetailMetrics.editorMinHeight : CommitDetailMetrics.messageMinHeight,
                spacing: 10
            ) {
                // One view either way: the layout needs exactly two.
                if editing {
                    editor
                } else {
                    // As tall as the message up to its cap, then a scroll view of that height.
                    ViewThatFits(in: .vertical) {
                        message
                        CardScrollView {
                            message
                                .frame(maxWidth: .infinity, alignment: .leading)
                        }
                        // Each commit's message starts at its top.
                        .id(commit.hash)
                    }
                    .modifier(MessageBox())
                }
                VStack(alignment: .leading, spacing: 10) {
                    PersonRow(session: session, role: "Author", name: commit.authorName, email: commit.authorEmail,
                              date: format(commit.authorDate))
                    if commit.committerName != commit.authorName || commit.committerEmail != commit.authorEmail {
                        PersonRow(session: session, role: "Committer", name: commit.committerName,
                                  email: commit.committerEmail, date: format(commit.committerDate))
                    }
                    ShaRow(hash: commit.hash)
                    parentsRow
                }
            }
            .padding(.top, SectionCardMetrics.accessoryGap)
            .onChange(of: token, initial: true) { UITiming.contentInfo(timingDetail) }
            .onChange(of: commit.hash) {
                editing = false
                saving = false
                summary = ""
                description = ""
            }
        } accessory: {
            HStack(spacing: 10) {
                copyButton
                if isHeadEditable || isRewordCandidate {
                    Button(action: editTapped) {
                        Image(systemName: "pencil")
                            .font(.callout)
                            .foregroundStyle(editing ? AnyShapeStyle(Color.accentColor) : AnyShapeStyle(.secondary))
                    }
                    .buttonStyle(RowIconButtonStyle(isOn: editing))
                    .disabled(saving)
                    .help("Edit message")
                    .accessibilityLabel("Edit message")
                }
                // AI (task 12.3): opens the result card; nothing is sent before the click.
                AIHookButton(title: "Explain", systemImage: "sparkles",
                             help: commit.isStash ? "Explain this stash with AI" : "Explain this commit with AI",
                             seam: "explain", small: true) {
                    session.startAI(.explainCommit(hash: commit.hash, message: fullMessage))
                }
            }
        }
        #if DEBUG
        .task(id: commit.hash) { await debugEditMessage() }
        #endif
    }

    /// The subject, a blank line and the body (when there is one).
    private var fullMessage: String {
        commit.body.isEmpty ? commit.subject : commit.subject + "\n\n" + commit.body
    }

    /// Copies the message; shows a check for a moment (the sha row's copy button).
    private var copyButton: some View {
        Button {
            NSPasteboard.general.clearContents()
            NSPasteboard.general.setString(fullMessage, forType: .string)
            copied = true
        } label: {
            // Both icons stay laid out so the button keeps one width when it swaps to the check.
            ZStack {
                Image(systemName: "square.on.square").opacity(copied ? 0 : 1)
                Image(systemName: "checkmark").opacity(copied ? 1 : 0)
            }
            .font(.callout)
            .foregroundStyle(.secondary)
        }
        .buttonStyle(RowIconButtonStyle())
        .help("Copy message")
        .accessibilityLabel("Copy message")
        .task(id: copied) {
            guard copied, (try? await Task.sleep(for: .seconds(1.5))) != nil else { return }
            copied = false
        }
    }

    /// HEAD of the checked-out branch, not a stash, no merge, rebase, cherry-pick or revert in progress: its message
    /// is edited in place.
    private var isHeadEditable: Bool {
        !commit.isStash && session.refs.value?.head.commit == commit.hash && session.currentBranch != nil
            && session.repoState?.isOperationInProgress != true
    }

    /// A cheap check for an older commit the rebase sheet may reword (one parent, on a branch); whether it is on the
    /// current branch's first-parent line is read only on click (`rebaseUnavailableReason` walks the log).
    private var isRewordCandidate: Bool {
        !commit.isStash && commit.parents.count == 1 && session.refs.value?.head.commit != commit.hash
            && session.currentBranch != nil && session.repoState?.isOperationInProgress != true
    }

    /// An open editor closes first (even if HEAD moved meanwhile). HEAD: opens the editor in this frame, filled from
    /// the shown message (no read). An older commit: the rebase sheet with its row on reword, or a toast saying why
    /// it cannot.
    private func editTapped() {
        if editing {
            editing = false
        } else if isHeadEditable {
            summary = commit.subject
            description = commit.body
            editing = true
        } else if isRewordCandidate {
            if let reason = session.rebaseUnavailableReason(from: commit.hash) {
                session.postToast(.warning("Edit Message", detail: reason))
            } else {
                session.openInteractiveRebase(from: commit.hash, reword: true)
            }
        }
    }

    /// The summary, a blank line and the description (when there is one), trimmed.
    private var draftMessage: String {
        let summary = summary.trimmingCharacters(in: .whitespacesAndNewlines)
        let description = description.trimmingCharacters(in: .whitespacesAndNewlines)
        return description.isEmpty ? summary : summary + "\n\n" + description
    }

    private var canSave: Bool {
        !saving && !summary.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            && draftMessage != fullMessage.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// The checked-out branch is in sync with its upstream: the edited commit is already on the remote.
    private var isPushed: Bool {
        guard let branch = session.refs.value?.localBranches.first(where: \.isHead) else { return false }
        return branch.upstream != nil && !branch.upstreamGone && branch.ahead == 0
    }

    /// The inline editor in the message's place: summary, description, the pushed note, Cancel and Update Message.
    private var editor: some View {
        VStack(alignment: .leading, spacing: 8) {
            TextField("Summary", text: $summary)
                .textFieldStyle(.settings)
                .labelsHidden()
                .focused($summaryFocused)
                // Next run-loop turn, once the field is in the window.
                .onAppear { DispatchQueue.main.async { summaryFocused = true } }
                .onKeyPress(.escape) {
                    editing = false
                    return .handled
                }
            TextEditor(text: $description)
                .font(.body)
                .settingsTextEditor()
                .frame(height: 72)
                .overlay(alignment: .topLeading) {
                    if description.isEmpty {
                        Text("Description")
                            .foregroundStyle(.tertiary)
                            .padding(.horizontal, 11)
                            .padding(.vertical, 8)
                            .allowsHitTesting(false)
                    }
                }
                .onKeyPress(.escape) {
                    editing = false
                    return .handled
                }
            if isPushed {
                Text("Already pushed: a force push will be needed.")
                    .font(.settingsCaption)
                    .foregroundStyle(.secondary)
            }
            HStack(spacing: 8) {
                Spacer(minLength: 0)
                Button("Cancel") { editing = false }
                    .buttonStyle(RowTextButtonStyle(formRow: true))
                    .keyboardShortcut(.cancelAction)
                    .disabled(saving)
                Button(action: save) {
                    HStack(spacing: 6) {
                        if saving { ProgressView().controlSize(.mini) }
                        Text("Update Message")
                    }
                }
                .buttonStyle(RowTextButtonStyle(formRow: true, prominent: true))
                .keyboardShortcut(.return, modifiers: .command)
                .disabled(!canSave)
                .help("Update Message (⌘↩)")
            }
        }
        .disabled(saving)
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    /// Rewrites HEAD's message (the WIP box's commit path): a success toast and the editor closes, or the failure
    /// toast and the editor keeps the text. The selection then moves to the new HEAD.
    private func save() {
        guard canSave else { return }
        let hash = commit.hash
        let write = RepoSession.Write.editMessage(commit: hash, message: draftMessage)
        let title = "Edit Message"
        saving = true
        let endOperation = session.beginOperation(title)
        Task {
            do {
                try await session.perform(write)
                session.postToast(.success(title))
                editing = false
                // A pushed commit stays in the log (its remote branch), so the selection does not drop by itself.
                if session.graphSelection == [.commit(hash)], let head = session.refs.value?.head.commit, head != hash {
                    session.selectGraph([.commit(head)])
                }
            } catch {
                // Only in its toast, not in the card too.
                session.report(OperationFailure(title: title, write: write, error: error,
                                                message: RepoSession.writeMessage(for: error)))
            }
            endOperation()
            saving = false
        }
    }

    #if DEBUG
    /// DEBUG `-HistqEditMessage open|save:<summary>` (QA): once the `-HistqSelect` commit's card shows and the refs
    /// and the log are read, `open` presses Edit; `save:<summary>` opens the editor, sets the summary and presses
    /// Update Message. Once per launch.
    private func debugEditMessage() async {
        guard !Self.debugEditMessageDone, let spec = AppState.launchFlag("-HistqEditMessage"),
              let target = AppState.launchSelection?.value
        else { return }
        for _ in 0..<300 {
            if session.refs.value != nil, session.log.value != nil, session.graphSelection == [.commit(target)] {
                break
            }
            guard (try? await Task.sleep(for: .milliseconds(100))) != nil else { return }
        }
        guard !Self.debugEditMessageDone, session.graphSelection == [.commit(target)] else { return }
        Self.debugEditMessageDone = true
        if spec == "open" {
            editTapped()
        } else if spec.hasPrefix("save:") {
            if !editing { editTapped() }
            guard editing else { return }
            summary = String(spec.dropFirst("save:".count))
            save()
        }
    }

    private static var debugEditMessageDone = false
    #endif

    private var message: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(commit.subject)
                .font(.body)
                .fixedSize(horizontal: false, vertical: true)
            if !commit.body.isEmpty {
                Text(commit.body)
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .textSelection(.enabled)
    }

    /// The parents, each a link to its row; a stash shows only the commit it was made on.
    @ViewBuilder private var parentsRow: some View {
        let parents = commit.isStash ? Array(commit.parents.prefix(1)) : commit.parents
        if !parents.isEmpty {
            HStack(spacing: 8) {
                Text(commit.isStash ? "Base" : parents.count == 1 ? "Parent" : "Parents")
                    .font(.settingsCaption)
                    .foregroundStyle(.secondary)
                    .frame(width: InfoMetrics.labelWidth, alignment: .leading)
                ForEach(parents, id: \.self) { parent in
                    Button(String(parent.prefix(7))) {
                        session.selectGraph([.commit(parent)])
                    }
                    .buttonStyle(RowTextButtonStyle(compact: true))
                    .help("Show \(parent)")
                }
                Spacer(minLength: 0)
            }
        }
    }

    private func format(_ date: Date) -> String {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: Locale.current.identifier)
        formatter.dateFormat = dateFormat
        return formatter.string(from: date)
    }
}

/// The info card's body: the message (first view), then the other rows (second view) at their own height, `spacing`
/// apart, `maxHeight` in all at most. The message is offered what the rows leave (`minMessageHeight` at least) and
/// takes its own height: unlike `.frame(maxHeight:)`, which grows to what it is offered, a short message stays as tall
/// as its text. One pass, no measured state, so a select lays the card out once.
private struct CappedMessageLayout: Layout {
    let maxHeight: CGFloat
    let minMessageHeight: CGFloat
    let spacing: CGFloat

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        guard subviews.count == 2 else { return .zero }
        let width = proposal.width ?? subviews.map { $0.sizeThatFits(.unspecified).width }.max() ?? 0
        let (message, rows) = heights(width: width, offered: proposal.height, subviews: subviews)
        return CGSize(width: width, height: message + spacing + rows)
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        guard subviews.count == 2 else { return }
        let (message, rows) = heights(width: bounds.width, offered: proposal.height, subviews: subviews)
        subviews[0].place(at: bounds.origin, anchor: .topLeading,
                          proposal: ProposedViewSize(width: bounds.width, height: message))
        subviews[1].place(at: CGPoint(x: bounds.minX, y: bounds.minY + message + spacing), anchor: .topLeading,
                          proposal: ProposedViewSize(width: bounds.width, height: rows))
    }

    /// The message's height (capped) and the rows' (their own).
    private func heights(width: CGFloat, offered: CGFloat?, subviews: Subviews) -> (CGFloat, CGFloat) {
        let rows = subviews[1].sizeThatFits(ProposedViewSize(width: width, height: nil)).height
        let budget = min(offered ?? maxHeight, maxHeight)
        let cap = max(minMessageHeight, budget - rows - spacing)
        let message = subviews[0].sizeThatFits(ProposedViewSize(width: width, height: cap)).height
        return (min(message, cap), rows)
    }
}

private enum InfoMetrics {
    static let labelWidth: CGFloat = 52
    static let avatar: CGFloat = 24
}

/// An avatar, the name, then the email and the date under it.
private struct PersonRow: View {
    let session: RepoSession
    let role: String
    let name: String
    let email: String
    let date: String

    var body: some View {
        HStack(spacing: 8) {
            // On the avatar: the text beside it is selectable and shows the text menu.
            AvatarImage(email: email, name: name, size: InfoMetrics.avatar)
                .authorEmojiMenu(email: email, name: name, session)
            VStack(alignment: .leading, spacing: 2) {
                HStack(spacing: 6) {
                    Text(name)
                        .font(.callout.weight(.medium))
                        .lineLimit(1)
                    Text(role.lowercased())
                        .font(.caption)
                        .foregroundStyle(.tertiary)
                }
                Text(email.isEmpty ? date : "\(email) · \(date)")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .truncationMode(.middle)
            }
            .textSelection(.enabled)
        }
        .accessibilityElement(children: .combine)
    }
}

/// The full sha (cut in the middle when narrow) and a copy button that shows a check for a moment.
private struct ShaRow: View {
    let hash: String
    @State private var copied = false

    var body: some View {
        HStack(spacing: 8) {
            Text("SHA")
                .font(.settingsCaption)
                .foregroundStyle(.secondary)
                .frame(width: InfoMetrics.labelWidth, alignment: .leading)
            Text(hash)
                .font(.callout.monospaced())
                .lineLimit(1)
                .truncationMode(.middle)
                .textSelection(.enabled)
            Button {
                NSPasteboard.general.clearContents()
                NSPasteboard.general.setString(hash, forType: .string)
                copied = true
            } label: {
                // Both icons stay laid out so the button keeps one width when it swaps to the check.
                ZStack {
                    Image(systemName: "square.on.square").opacity(copied ? 0 : 1)
                    Image(systemName: "checkmark").opacity(copied ? 1 : 0)
                }
                .font(.callout)
                .foregroundStyle(.secondary)
            }
            .buttonStyle(RowIconButtonStyle())
            .help("Copy SHA")
            .accessibilityLabel("Copy SHA")
            .task(id: copied) {
                guard copied, (try? await Task.sleep(for: .seconds(1.5))) != nil else { return }
                copied = false
            }
            Spacer(minLength: 0)
        }
    }
}

private extension View {
    /// Set / Remove Author Emoji on right-click; no menu for an author that cannot have one.
    func authorEmojiMenu(email: String, name: String, _ session: RepoSession) -> some View {
        modifier(AuthorEmojiMenu(email: email, name: name, session: session))
    }
}

/// Rebuilds the menu when this author's emoji changes, so Remove Author Emoji shows only while there is one.
private struct AuthorEmojiMenu: ViewModifier {
    let email: String
    let name: String
    let session: RepoSession
    @State private var revision = 0

    func body(content: Content) -> some View {
        Group {
            if AvatarStore.shared.canSetEmoji(email: email, name: name) {
                content.contextMenu {
                    let _ = revision
                    MenuEntriesView(entries: RepoMenus.authorEmoji(email: email, name: name, session))
                }
            } else {
                content
            }
        }
        .onReceive(NotificationCenter.default.publisher(for: AvatarStore.didChange)) { note in
            guard let changed = note.userInfo?[AvatarStore.emailKey] as? String else { return revision &+= 1 }
            if AvatarStore.matches(email: email, name: name, changed: changed) {
                revision &+= 1
            }
        }
    }
}

/// An author's avatar from `AvatarStore` (never blocks: a generated one until the real one arrives).
private struct AvatarImage: View {
    let email: String
    let name: String
    let size: CGFloat
    @State private var image: NSImage?
    @Environment(\.displayScale) private var scale

    var body: some View {
        Group {
            if let image {
                Image(nsImage: image).resizable()
            } else {
                Circle().fill(Palette.skeletonFill)
            }
        }
        .frame(width: size, height: size)
        .clipShape(Circle())
        .accessibilityHidden(true)
        .onAppear(perform: load)
        .onChange(of: email) { load() }
        .onReceive(NotificationCenter.default.publisher(for: AvatarStore.didChange)) { note in
            if let changed = note.userInfo?[AvatarStore.emailKey] as? String,
               !AvatarStore.matches(email: email, name: name, changed: changed)
            {
                return
            }
            load()
        }
    }

    private func load() {
        image = AvatarStore.shared.avatar(email: email, name: name, pixels: Int((size * scale).rounded(.up)))
    }
}
