// The palette's File History… and Blame…: a small modal with one field that searches the tab's tracked files (`git ls-files` in
// its worktree). The card shows in the frame of the palette row; the files are read meanwhile, and a dropdown of the
// best matches shows under the field as soon as something is typed, ranked like the palette's rows
// (`CommandPaletteModel`). Up and Down move the highlight, Return or a click opens the file's history or blame, as its
// File History and Blame menu items do, and closes the modal.
import AppKit
import SwiftUI

struct FileSearchModal: View {
    let session: RepoSession
    /// Blame… (the file's blame at the working tree); else File History… (its history from HEAD).
    let blame: Bool
    let onClose: () -> Void

    @State private var query = ""
    /// The files ranked for `query`; nil until they are read.
    @State private var files: CommandPaletteModel?
    @State private var loadError: String?
    @State private var selectedID: PaletteItem.ID?
    @FocusState private var fieldFocused: Bool

    private static let listHeight: CGFloat = 260

    var body: some View {
        ModalCard(title: blame ? "Blame" : "File History",
                  subtitle: "Type a file name of \(session.url.lastPathComponent).",
                  systemImage: blame ? "person.text.rectangle" : "clock.arrow.circlepath", width: 520) {
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
            let paths = try await session.trackedFiles()
            var snapshot = PaletteSnapshot()
            for path in paths {
                snapshot.add((path as NSString).lastPathComponent, detail: path, section: .files,
                             systemImage: "doc.text") { [session, blame, onClose] in
                    // The modal first: `selectTool` may ask before leaving the conflict editor.
                    onClose()
                    session.selectTool(blame ? .blame(path: path, rev: nil)
                        : .fileHistory(path: path, rev: nil, follow: false))
                }
            }
            files = CommandPaletteModel(snapshot: snapshot, query: query)
            UITiming.content("file search \(paths.count)")
        } catch is CancellationError {
            return
        } catch {
            loadError = error.localizedDescription
        }
    }

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
