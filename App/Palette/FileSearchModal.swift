// The palette's File History…, Blame… and Edit File…: a small modal with one field that searches the tab's tracked files
// (`git ls-files` in its worktree; Edit File… adds the untracked ones). The card shows in the frame of the palette row; the
// files are read meanwhile, and a dropdown of the best matches shows under the field as soon as something is typed,
// ranked like the palette's rows (`CommandPaletteModel`). Up and Down move the highlight, Return or a click opens the
// file's history or blame, as its File History and Blame menu items do, or the file editor, and closes the modal.
import AppKit
import SwiftUI

/// What a pick in `FileSearchModal` opens.
enum FileSearchMode {
    /// File History…: the file's history from HEAD.
    case history
    /// Blame…: the file's blame at the working tree.
    case blame
    /// Edit File…: the file of the working tree in the file editor.
    case edit

    var title: String {
        switch self {
        case .history: "File History"
        case .blame: "Blame"
        case .edit: "Edit File"
        }
    }

    var systemImage: String {
        switch self {
        case .history: "clock.arrow.circlepath"
        case .blame: "person.text.rectangle"
        case .edit: "square.and.pencil"
        }
    }
}

struct FileSearchModal: View {
    let session: RepoSession
    let mode: FileSearchMode
    let onClose: () -> Void

    @State private var query = ""
    /// The files ranked for `query`; nil until they are read.
    @State private var files: CommandPaletteModel?
    @State private var loadError: String?
    @State private var selectedID: PaletteItem.ID?
    @FocusState private var fieldFocused: Bool

    private static let listHeight: CGFloat = 260

    var body: some View {
        ModalCard(title: mode.title, subtitle: subtitle, systemImage: mode.systemImage, width: 520) {
            VStack(spacing: PanelContainerMetrics.padding) {
                TextField("File", text: $query, prompt: Text("Search files"))
                    .textFieldStyle(.modal)
                    .labelsHidden()
                    .autocorrectionDisabled()
                    .focused($fieldFocused)
                    .onKeyPress(keys: [.upArrow, .downArrow, .return, .escape]) { press in
                        handleKey(press)
                    }
                if !query.isEmpty {
                    results
                }
            }
            .padding(.horizontal, ModalFooterMetrics.trailingPadding)
        } actions: {
            Button("Cancel", action: onClose)
                .buttonStyle(RowTextButtonStyle(formRow: true))
                .keyboardShortcut(.cancelAction)
        }
        // Under the palette's place, growing down as the dropdown opens (`ModalHost` would center it).
        .padding(.top, CommandPaletteMetrics.topMargin - ModalMetrics.margin)
        .frame(maxHeight: .infinity, alignment: .top)
        .onAppear {
            UITiming.placeholder("file search")
            #if DEBUG
            // QA: `-HistqFileSearch "<query>"` types the query.
            if let typed = AppState.launchFlag("-HistqFileSearch") { query = typed }
            #endif
            // The card is installed on this turn; the field takes the focus on the next one.
            DispatchQueue.main.async { fieldFocused = true }
        }
        .task { await load() }
        .onChange(of: query) { files?.query = query }
        .onChange(of: files?.ranked) { _, ranked in selectedID = ranked?.first?.id }
    }

    private var subtitle: String {
        let repo = session.url.lastPathComponent
        return mode == .edit ? "Type the name of a text file of \(repo) to edit." : "Type a file name of \(repo)."
    }

    private var results: some View {
        ScrollViewReader { proxy in
            ScrollView {
                if let loadError {
                    message(loadError)
                } else if let files, files.showsNoMatches {
                    message("No matching files")
                } else if let files {
                    // Not lazy: at most 50 rows, and `scrollTo` lands short on rows a lazy stack has not laid out.
                    VStack(alignment: .leading, spacing: 2) {
                        ForEach(files.ranked) { item in
                            CommandPaletteRow(item: item, isSelected: item.id == activeID) { activate(item) }
                                .id(item.id)
                        }
                    }
                    .padding(PanelContainerMetrics.padding)
                } else {
                    message("Reading files…")
                }
            }
            .scrollContentBackground(.hidden)
            .onChange(of: selectedID) { _, id in
                guard let id else { return }
                proxy.scrollTo(id)
            }
        }
        .frame(maxWidth: .infinity)
        .frame(height: Self.listHeight)
        .clipShape(RoundedRectangle(cornerRadius: SettingsMetrics.cardRadius, style: .continuous))
        .modifier(GlassCard(cornerRadius: SettingsMetrics.cardRadius))
    }

    private func message(_ text: String) -> some View {
        Text(text)
            .font(.settingsCaption)
            .foregroundStyle(.secondary)
            .frame(maxWidth: .infinity, minHeight: 120)
    }

    // MARK: Files

    /// Reads the tracked files off the main actor, then ranks them for what is typed by then.
    private func load() async {
        do {
            let tracked = try await session.trackedFiles()
            let paths = mode == .edit ? editablePaths(tracked) : tracked
            var snapshot = PaletteSnapshot()
            for path in paths {
                snapshot.add((path as NSString).lastPathComponent, detail: path, section: .files,
                             systemImage: "doc.text") { [session, mode, onClose] in
                    // The modal first: `selectTool` and `openEditor` may ask before leaving an unsaved editor.
                    onClose()
                    switch mode {
                    case .history: session.selectTool(.fileHistory(path: path, rev: nil, follow: false))
                    case .blame: session.selectTool(.blame(path: path, rev: nil))
                    case .edit: session.openEditor(path: path)
                    }
                }
            }
            files = CommandPaletteModel(snapshot: snapshot, query: query)
            UITiming.content("file search \(paths.count)")
            #if DEBUG
            await debugPick()
            #endif
        } catch is CancellationError {
            return
        } catch {
            loadError = error.localizedDescription
        }
    }

    /// Edit File…'s files: the tracked ones and the status's untracked ones, less those the editor can never open, told
    /// from what is at hand (`RepoSession.canEdit`, no read): images, files deleted in the working tree or conflicted,
    /// submodules, untracked folders. A file its read refuses (binary, not UTF-8, too large, a symlink) stays: the
    /// editor then says why.
    private func editablePaths(_ tracked: [String]) -> [String] {
        let entries = session.status.value?.entries ?? []
        // Each path's entry, looked up once (the first, as `wipFileTarget` takes it): no scan of the status per file.
        let changed = Dictionary(entries.map { ($0.path, $0) }, uniquingKeysWith: { first, _ in first })
        let submodules = Set(session.submodules.value?.map(\.path) ?? [])
        let untracked = entries.lazy.filter { $0.kind == .untracked }.map(\.path)
        // By extension, once each: an unchanged file is an image or not by `FileTarget.isImage`'s rule alone.
        var images: [String: Bool] = [:]
        return (tracked + untracked).filter { path in
            if submodules.contains(path) { return false }
            if let entry = changed[path] {
                return session.canEdit(session.wipFileTarget(path, entry: entry), entry: entry)
            }
            let ext = (path as NSString).pathExtension
            if let isImage = images[ext] { return !isImage }
            let isImage = FileTarget(source: .wip, file: FileChange(kind: .modified, path: path)).isImage
            images[ext] = isImage
            return !isImage
        }
    }

    #if DEBUG
    /// QA: `-HistqFileSearchPick YES` picks the first ranked row once the files are read, as Return does, and logs
    /// `filesearch pick <path>` (or that no row matched) to `operations.txt`.
    private func debugPick() async {
        guard AppState.launchFlag("-HistqFileSearchPick") == "YES", !query.isEmpty, let files else { return }
        // The rank runs off the main actor.
        for _ in 0..<250 {
            if files.isRankFresh { break }
            try? await Task.sleep(for: .milliseconds(20))
        }
        guard let item = files.ranked.first else { return RepoMenus.debugLog("filesearch pick: no row for \(query)") }
        RepoMenus.debugLog("filesearch pick \(item.detail)")
        activate(item)
    }
    #endif

    // MARK: Selection

    /// The highlighted row: the selected one while it is listed, else the first.
    private var activeID: PaletteItem.ID? {
        let items = files?.ranked ?? []
        if let selectedID, items.contains(where: { $0.id == selectedID }) { return selectedID }
        return items.first?.id
    }

    /// Up, Down, Return and Escape, as in the palette.
    private func handleKey(_ press: KeyPress) -> KeyPress.Result {
        // Return commits an IME syllable: it must not open the highlighted file.
        if (NSApp.keyWindow?.firstResponder as? NSTextView)?.hasMarkedText() == true { return .ignored }
        guard press.modifiers.intersection([.command, .shift, .option, .control]).isEmpty else { return .ignored }
        switch press.key {
        case .upArrow: moveSelection(by: -1)
        case .downArrow: moveSelection(by: 1)
        case .escape: onClose()
        case .return:
            guard press.phase == .down, !query.isEmpty else { return .handled }
            if let activeID, let item = files?.ranked.first(where: { $0.id == activeID }) { activate(item) }
        default: return .ignored
        }
        return .handled
    }

    private func moveSelection(by delta: Int) {
        let items = files?.ranked ?? []
        guard !items.isEmpty else { return }
        guard let activeID, let index = items.firstIndex(where: { $0.id == activeID }) else {
            selectedID = items[0].id
            return
        }
        selectedID = items[min(max(index + delta, 0), items.count - 1)].id
    }

    /// Refuses a row left over from an older query.
    private func activate(_ item: PaletteItem) {
        files?.action(for: item)?()
    }
}
