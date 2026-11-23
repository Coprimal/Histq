// The file editor in panel 2 (column 4 in Columns): the controls card with the Diff / Split / Full file / Edit tabs,
// Wrap Lines, Save and close, a disk-change notice, and the file's card: its title row, then its text in an NSTextView
// (TextKit 1, line numbers, wrapped or not, syntax colours scanned off the main actor, its own undo). The text view
// outlives this view: it is made once per buffer and kept on the session (`RepoSession.editorScrollView`), so Edit ->
// Diff -> Edit, a layout switch or another window keep it.
import AppKit
import HistqCore
import SwiftUI

/// The open file's mode switch: Diff, Split and Full file (`session.diffMode`, a plain flip), and Edit when the file
/// can be edited (with a dot while its text is unsaved). A diff tab picked under the editor reads the diff again
/// (`showDiff`); Edit opens the editor or shows its kept buffer. Without Edit it looks as the diff's own tabs did.
struct FileModeTabs: View {
    let session: RepoSession
    let target: FileTarget

    /// A view-only tab: `DiffMode` itself has no Edit (it feeds the Settings default view and the palette).
    enum Mode: Hashable {
        case diff(DiffMode)
        case edit
    }

    var body: some View {
        // A kept buffer keeps its tab while its file can't be opened anew (deleted or conflicted on disk meanwhile).
        let editable = session.canEdit(target) || session.isEditedFile(target)
        let dirty = session.editor?.isDirty == true
        // Only the Edit tab has a tooltip (an empty one shows nothing); without it, none, as before.
        let help: ((Mode) -> String)? = editable
            ? { mode in mode != .edit ? "" : dirty ? "Edit the file (unsaved changes)" : "Edit the file" } : nil
        // Its own track beside the action panel, as tall (`ActionPanelRow.height`), in the callout size of the panel's
        // buttons, not the compact tabs' caption size (user, 2026-11-22).
        CapsuleTabs(selection: selection, tabs: DiffMode.allCases.map(Mode.diff) + (editable ? [.edit] : []),
                    title: { title($0, dirty: dirty).font(.callout) }, compact: true, help: help, cardTrack: true)
    }

    private var selection: Binding<Mode> {
        Binding(
            get: { [session] in session.editor?.showsEditor == true ? .edit : .diff(session.diffMode) },
            set: { [session, target] mode in
                switch mode {
                case .edit:
                    // The kept buffer when it is this file's, else a new editor.
                    session.openEditor(path: target.path)
                case .diff(let diffMode):
                    session.diffMode = diffMode
                    // Only under the editor is the diff not read (`fileDiff` is idle there): read it now.
                    if session.editor?.showsEditor == true { session.showDiff() }
                }
            })
    }

    private func title(_ mode: Mode, dirty: Bool) -> Text {
        switch mode {
        case .diff(let diffMode):
            return Text(diffMode.title)
        case .edit:
            guard dirty else { return Text("Edit") }
            let dot = Text(Image(systemName: "circle.fill")).font(.system(size: 6)).baselineOffset(1.5)
            return Text("Edit \(dot)")
        }
    }
}

/// Panel 2 while the Edit tab shows: the controls card at once, a disk-change notice when there is one, then the file's
/// card: its title row (`EditorFileHeader`, as the diff's file row), then the text (a skeleton until it is read, a
/// notice when the file can't be edited).
struct FileEditorView: View {
    let session: RepoSession
    let target: FileTarget
    @Environment(WindowModel.self) private var model
    /// The text view's find bar shows: Esc closes it, not the editor.
    @State private var findBarShown = false

    var body: some View {
        VStack(spacing: SectionCardMetrics.spacing) {
            FileEditorControlsCard(session: session, target: target, findBarShown: findBarShown)
            if let editor = session.editor, let change = editor.diskChange, case .loaded(.text) = editor.content {
                EditorDiskNotice(session: session, change: change, saving: editor.saving)
            }
            content
        }
    }

    private var content: some View {
        Group {
            switch session.editor?.content {
            case nil, .idle?:
                // Only while the editor closes: no placeholder, no timing line.
                Color.clear
            case .loading?:
                EditorCard(target: target) {
                    PlaceholderCard(
                        token: session.fileToken, detail: session.fileDetail,
                        isCurrent: { [model, session] in
                            model.selectedSession === session && session.editor?.showsEditor == true
                        }
                    ) {
                        EditorPlaceholder()
                    }
                }
            case .loaded(.text)?:
                // `content` is logged by the text view's controller once the text is in it.
                EditorCard(target: target) {
                    EditorTextHost(session: session, loadID: session.editor?.loadID ?? 0, findBarShown: $findBarShown)
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                }
            case .loaded(.refused(let refusal))?:
                EditorCard(target: target, contentPadding: SettingsMetrics.cardPadding) {
                    FileNotice(systemImage: Self.icon(refusal), message: Self.message(refusal)) {
                        Button("Back to Diff") { session.showDiff() }
                            .buttonStyle(RowTextButtonStyle(formRow: true))
                    }
                }
                .onAppear { UITiming.content("\(session.fileDetail) refused") }
            case .failed(let message)?:
                EditorCard(target: target, contentPadding: SettingsMetrics.cardPadding) {
                    FileNotice(systemImage: "exclamationmark.triangle", message: message) {
                        Button("Back to Diff") { session.showDiff() }
                            .buttonStyle(RowTextButtonStyle(formRow: true))
                    }
                }
                .onAppear { UITiming.content("\(session.fileDetail) failed") }
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
    }

    private static func icon(_ refusal: EditableFile.Refusal) -> String {
        switch refusal {
        case .binary: "doc.zipper"
        case .tooLarge: "doc.badge.clock"
        case .missing: "questionmark.folder"
        case .symlink: "arrow.triangle.turn.up.right.diamond"
        case .unsafePath, .notRegular, .notUTF8, .unreadable: "exclamationmark.triangle"
        }
    }

    private static func message(_ refusal: EditableFile.Refusal) -> String {
        switch refusal {
        case .unsafePath: "Histq can't edit a file at this path."
        case .missing: "This file is not in the working tree."
        case .symlink: "This file is a symbolic link. Histq does not edit through links."
        case .notRegular: "This is not a regular file."
        case .tooLarge(let bytes):
            "This file is \(ByteCountFormatter.string(fromByteCount: Int64(bytes), countStyle: .file)), over the "
                + "\(ByteCountFormatter.string(fromByteCount: Int64(RepoSession.fileSizeLimit), countStyle: .file)) "
                + "Histq edits."
        case .binary: "Histq does not edit binary files."
        case .notUTF8: "This file is not UTF-8 text. Histq edits UTF-8 files only."
        case .unreadable(let code): "Histq could not read this file: \(String(cString: strerror(code)))."
        }
    }
}

/// The file's card under the controls: its title row (`EditorFileHeader`), then `content` (0 `contentPadding` for the
/// text and its skeleton, which run to the card's edges; a notice gets the card's padding, below the row only).
private struct EditorCard<Content: View>: View {
    let target: FileTarget
    var contentPadding: CGFloat = 0
    @ViewBuilder let content: () -> Content
    @Environment(\.cardExtraPadding) private var extraPadding
    @Environment(\.cardExtraVerticalPadding) private var extraVerticalPadding

    var body: some View {
        SectionCard(nil, contentPadding: 0) {
            EditorFileHeader(file: target.file)
            VStack(alignment: .leading, spacing: 0) {
                content()
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
            .padding(.horizontal, contentPadding == 0 ? 0 : contentPadding + extraPadding)
            .padding(.bottom, contentPadding == 0 ? 0 : contentPadding + extraVerticalPadding)
        }
    }
}

/// The edited file's row, the header of its card: the status icon, then "folder / name" (the folder secondary,
/// truncating from its head, else hidden). At the insets and height of the diff's file row (`DiffFileHeader`), so the
/// title stays in place between Diff and Edit.
private struct EditorFileHeader: View {
    let file: FileChange
    @Environment(\.cardExtraPadding) private var extraPadding
    @Environment(\.cardExtraVerticalPadding) private var extraVerticalPadding

    /// The narrowest truncated folder; narrower, it hides.
    private static let folderMinWidth: CGFloat = 40

    var body: some View {
        HStack(spacing: 8) {
            title
            Spacer(minLength: 8)
        }
        .padding(.horizontal, SettingsMetrics.cardPadding + extraPadding)
        .frame(height: SectionCardMetrics.headerHeight)
        .padding(.top, extraVerticalPadding * 2 / 3)
    }

    private var title: some View {
        HStack(spacing: 8) {
            Image(systemName: file.systemImage)
                .foregroundStyle(file.tint)
                .accessibilityHidden(true)
            HStack(spacing: 0) {
                if !file.folder.isEmpty {
                    ViewThatFits(in: .horizontal) {
                        folderText(file.folder)
                        folderText(file.folder)
                            .truncationMode(.head)
                            .frame(minWidth: Self.folderMinWidth, idealWidth: Self.folderMinWidth, alignment: .leading)
                        Color.clear
                            .frame(width: 0)
                    }
                }
                Text(file.folder.isEmpty ? file.name : " " + file.name)
                    .lineLimit(1)
                    .layoutPriority(1)
            }
            .help(file.path)
            .accessibilityElement(children: .ignore)
            .accessibilityLabel("Editing \(file.path)")
            .layoutPriority(1)
        }
    }

    private func folderText(_ folder: String) -> some View {
        Text(folder.replacing("/", with: " / ") + " /")
            .foregroundStyle(.secondary)
            .lineLimit(1)
    }
}

/// The row above the editor, as the diff's: the mode tabs with Edit selected in their own track, then the action panel
/// (`ActionPanelRow`) with Wrap Lines (the diff's switch and preference), Save and close (Esc, asking first when the
/// text is unsaved) on its right. A failed save shows under the panel's row. As the panel narrows, Save turns into an
/// icon.
private struct FileEditorControlsCard: View {
    let session: RepoSession
    let target: FileTarget
    let findBarShown: Bool
    @AppStorage(PrefKey.diffWrapLines.rawValue, store: Preferences.defaults) private var wrapLines = false

    var body: some View {
        HStack(alignment: .top, spacing: SectionCardMetrics.spacing) {
            FileModeTabs(session: session, target: target)
                .fixedSize()
            VStack(alignment: .leading, spacing: 4) {
                ViewThatFits(in: .horizontal) {
                    row(saveAsIcon: false)
                    row(saveAsIcon: true)
                }
                .frame(height: ActionPanelRow.rowHeight)
                if let error = session.editor?.error {
                    ErrorText(message: error)
                }
            }
            .modifier(ActionPanelRow())
        }
    }

    private func row(saveAsIcon: Bool) -> some View {
        HStack(spacing: 12) {
            Spacer(minLength: 0)
            DiffControlsCard.iconButton("text.alignleft", help: wrapLines ? "Don't Wrap Lines" : "Wrap Lines",
                                        isOn: wrapLines) {
                wrapLines.toggle()
            }
            saveButton(asIcon: saveAsIcon)
            closeButton
        }
    }

    @ViewBuilder private func saveButton(asIcon: Bool) -> some View {
        let editor = session.editor
        let saving = editor?.saving == true
        let isText = if case .loaded(.text)? = editor?.content { true } else { false }
        let canSave = isText && editor?.isDirty == true && !saving && editor?.diskChange != .deleted
        Button {
            session.saveEditor()
        } label: {
            if asIcon {
                Image(systemName: "square.and.arrow.down")
            } else {
                Label(saving ? "Saving…" : "Save", systemImage: "square.and.arrow.down")
                    .lineLimit(1)
            }
        }
        .buttonStyle(RowTextButtonStyle(prominent: true))
        .fixedSize()
        .disabled(!canSave)
        .help(editor?.diskChange == .deleted ? "The file was deleted on disk: copy the text to keep it"
            : "Save the file (⌘S); it is not staged")
        .accessibilityLabel("Save")
    }

    private var closeButton: some View {
        Button {
            // Esc while the find bar shows closes the bar, whichever of the two saw the key first.
            if (session.editorTextDelegate as? EditorTextController)?.hideFindBarOnEscape() == true { return }
            session.closeFileAsking()
        } label: {
            Image(systemName: "xmark")
                .font(.system(size: ActionPanelRow.iconFont, weight: .semibold))
                .foregroundStyle(.secondary)
                .frame(width: ActionPanelRow.iconSize, height: ActionPanelRow.iconSize)
        }
        .buttonStyle(RowIconButtonStyle())
        .keyboardShortcut(findBarShown ? nil : .cancelAction)
        .help("Close the editor (Esc; asks first when there are unsaved changes)")
        .accessibilityLabel("Close the editor")
    }
}

/// The file changed or went on disk while its text is unsaved: Reload (drops the text) or Keep Mine (saves over the
/// change); a deleted file offers Copy Text and Close, and is never made again.
private struct EditorDiskNotice: View {
    let session: RepoSession
    let change: FileEditor.DiskChange
    let saving: Bool

    var body: some View {
        SectionCard(nil, contentPadding: 8,
                    tone: change == .deleted ? Color(nsColor: Palette.diffRemovedSign) : Palette.conflictTone) {
            HStack(spacing: 12) {
                Label {
                    Text(message)
                        .fixedSize(horizontal: false, vertical: true)
                } icon: {
                    IconImage(change == .deleted ? "trash" : "exclamationmark.triangle")
                }
                .foregroundStyle(.secondary)
                Spacer(minLength: 8)
                switch change {
                case .modified:
                    Button("Reload") { session.reloadEditor() }
                        .buttonStyle(RowTextButtonStyle())
                        .fixedSize()
                        .help("Read the file again; your unsaved changes are lost")
                    Button("Keep Mine") { session.keepMine() }
                        .buttonStyle(RowTextButtonStyle(prominent: true))
                        .fixedSize()
                        .help("Save your text over the change on disk")
                case .deleted:
                    Button("Copy Text") { session.copyEditorText() }
                        .buttonStyle(RowTextButtonStyle())
                        .fixedSize()
                        .help("Copy the editor's text to the clipboard")
                    Button("Close") { session.closeFileAsking() }
                        .buttonStyle(RowTextButtonStyle())
                        .fixedSize()
                        .help("Close the editor (asks first when there are unsaved changes)")
                }
            }
            .padding(.horizontal, 4)
            .disabled(saving)
        }
    }

    private var message: String {
        switch change {
        case .modified: "This file changed on disk since it was opened or saved."
        case .deleted: "This file was deleted on disk. Saving won't create it again."
        }
    }
}

/// The editor's skeleton: line rows (a number gutter and a text capsule) at the code font's line height.
private struct EditorPlaceholder: View {
    private static let widths: [CGFloat] = [0.45, 0.7, 0.55, 0.3, 0.62, 0.5, 0.75, 0.35, 0.6, 0.4, 0.66, 0.52]
    @AppStorage(PrefKey.codeFontSize.rawValue, store: Preferences.defaults) private var fontSize = 12.0

    var body: some View {
        let metrics = DiffLayout.Metrics.of(fontSize)
        VStack(alignment: .leading, spacing: 0) {
            ForEach(Self.widths.indices, id: \.self) { index in
                HStack(spacing: 12) {
                    SkeletonLine(width: 20, height: 9)
                    SkeletonLine(fraction: Self.widths[index], height: 10)
                }
                .padding(.horizontal, 10)
                .frame(height: metrics.lineHeight)
            }
        }
        .padding(.vertical, 6)
        // The text fills the card: so does its skeleton.
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
    }
}

/// Hosts the session's text view (made once per buffer by `EditorTextController.make`) in a plain container. The
/// scroll view is moved into each new host and only ever detached, never destroyed, so its text, undo history, caret
/// and scroll survive every unmount.
private struct EditorTextHost: NSViewRepresentable {
    let session: RepoSession
    /// The editor's load: a new one puts its text into the view (and only then).
    let loadID: Int
    @Binding var findBarShown: Bool
    @AppStorage(PrefKey.codeFontSize.rawValue, store: Preferences.defaults) private var fontSize = 12.0
    @AppStorage(PrefKey.diffWrapLines.rawValue, store: Preferences.defaults) private var wrapLines = false
    @Environment(\.tabIsShown) private var tabIsShown

    func makeNSView(context: Context) -> NSView {
        let container = NSView()
        container.isHidden = !tabIsShown
        // This host takes the scroll view from any older one (SwiftUI may mount it before dismantling that one).
        attach(to: container, taking: true)
        return container
    }

    func updateNSView(_ container: NSView, context: Context) {
        if container.isHidden == tabIsShown { container.isHidden = !tabIsShown }
        attach(to: container, taking: false)
    }

    /// Detaches what is still in this container only: a newer host may hold the scroll view already.
    static func dismantleNSView(_ container: NSView, coordinator: ()) {
        for view in container.subviews { view.removeFromSuperview() }
    }

    /// Puts the buffer's scroll view in `container` (`taking`: from another host too; else only a detached one), drops
    /// a dropped buffer's, and lets the controller apply the load, the font size and Wrap Lines.
    private func attach(to container: NSView, taking: Bool) {
        guard let controller = EditorTextController.make(for: session), let scroll = controller.scrollView else {
            return
        }
        for view in container.subviews where view !== scroll { view.removeFromSuperview() }
        if scroll.superview !== container, taking || scroll.superview == nil {
            scroll.removeFromSuperview()
            scroll.frame = container.bounds
            scroll.autoresizingMask = [.width, .height]
            container.addSubview(scroll)
        }
        let binding = $findBarShown
        scroll.onFindBarChange = { visible in
            if binding.wrappedValue != visible { binding.wrappedValue = visible }
        }
        if findBarShown != scroll.isFindBarVisible {
            let visible = scroll.isFindBarVisible
            // Not during this view update.
            Task { @MainActor in binding.wrappedValue = visible }
        }
        controller.show(loadID: loadID, fontSize: fontSize, wraps: wrapLines)
    }
}

/// The text view's delegate for its buffer's whole life (kept strongly in `RepoSession.editorTextDelegate`; the text
/// view's `delegate` is weak): the editor's own undo history, every user edit to `editorDidChange()`, the line
/// count, the ruler's redraw on scroll, the code font size, Wrap Lines and the syntax colours. Text set on load and
/// Reload is not an edit.
@MainActor
final class EditorTextController: NSObject, NSTextViewDelegate {
    private weak var session: RepoSession?
    private(set) weak var scrollView: EditorScrollView?
    private weak var textView: EditorTextView?
    private weak var ruler: EditorLineRuler?
    let path: String
    private let language: Language?
    /// This editor's undo history: never the window's, which hidden kept-alive tabs and the commit field share.
    private let undoManager = UndoManager()
    /// The load whose text is in the view, the font size it shows, and whether its lines wrap.
    private var shownLoadID: Int?
    private var shownFontSize: Double?
    private var shownWraps: Bool?
    /// True while the controller sets the text itself (load, font size): not a user edit.
    private var isSyncing = false
    /// The edit between `shouldChangeTextIn` and `textDidChange`, for the line count's change.
    private var pendingEdit: PendingEdit?
    /// When the edit's key came in, and when the last edit ended (DEBUG timing).
    private var keyStart: UInt64?
    private var lastEdit: UInt64?
    /// Bumped by every load and edit: a colour scan of older text is dropped.
    private var colourGeneration = 0
    private var colourTask: Task<Void, Never>?

    private enum PendingEdit {
        /// One edit: its line breaks counted from one character before it (a CR there may pair with an LF typed after
        /// it) to its end, and where its new text ends.
        case one(start: Int, newEnd: Int, oldBreaks: Int)
        /// More than one range (or an edit not seen before): the whole text is counted again.
        case many
    }

    /// How long typing pauses before the text is scanned for colours again.
    private static let colourDelay: Duration = .milliseconds(150)

    private static var styles: [CGFloat: [NSAttributedString.Key: Any]] = [:]

    /// The text's attributes at the current code font size, made once per size: Output's (fixed line height, tabs),
    /// but lines that wrap at a word. While Wrap Lines is off, the text container is unbounded, so nothing wraps.
    static var attributes: [NSAttributedString.Key: Any] {
        let size = DiffLayout.metrics.size
        if let attributes = styles[size] { return attributes }
        var attributes = ConflictOutputController.attributes
        if let style = (attributes[.paragraphStyle] as? NSParagraphStyle)?.mutableCopy() as? NSMutableParagraphStyle {
            style.lineBreakMode = .byWordWrapping
            attributes[.paragraphStyle] = style
        }
        styles[size] = attributes
        return attributes
    }

    private init(session: RepoSession, path: String) {
        self.session = session
        self.path = path
        language = LanguageTable.language(forPath: path)
    }

    /// The editor's text view, its scroll view and this controller, made once per buffer and stored on the session;
    /// the ones already made for this buffer otherwise. Nil without an editor.
    static func make(for session: RepoSession) -> EditorTextController? {
        guard let editor = session.editor else { return nil }
        if let controller = session.editorTextDelegate as? EditorTextController, controller.path == editor.path,
           controller.scrollView != nil, controller.textView != nil
        {
            return controller
        }
        let controller = EditorTextController(session: session, path: editor.path)
        // TextKit 1: fixed line fragments make every line (every row of a wrapped one) exactly `lineHeight` tall, as
        // the ruler draws.
        let textView = EditorTextView(usingTextLayoutManager: false)
        textView.isRichText = false
        textView.importsGraphics = false
        textView.allowsUndo = true
        textView.usesFindBar = true
        textView.isIncrementalSearchingEnabled = true
        textView.isAutomaticQuoteSubstitutionEnabled = false
        textView.isAutomaticDashSubstitutionEnabled = false
        textView.isAutomaticTextReplacementEnabled = false
        textView.isAutomaticSpellingCorrectionEnabled = false
        textView.isAutomaticTextCompletionEnabled = false
        textView.isAutomaticLinkDetectionEnabled = false
        textView.isAutomaticDataDetectionEnabled = false
        textView.isContinuousSpellCheckingEnabled = false
        textView.isGrammarCheckingEnabled = false
        textView.smartInsertDeleteEnabled = false
        textView.drawsBackground = false
        textView.insertionPointColor = .white
        textView.textColor = Palette.diffText
        textView.textContainerInset = NSSize(width: 6, height: 0)
        // No wrap to start with (`applyWrap` sets Wrap Lines): the text view grows sideways with its longest line.
        textView.isHorizontallyResizable = true
        textView.isVerticallyResizable = true
        textView.minSize = .zero
        textView.maxSize = NSSize(width: CGFloat.greatestFiniteMagnitude, height: .greatestFiniteMagnitude)
        textView.autoresizingMask = [.width]
        textView.textContainer?.widthTracksTextView = false
        textView.textContainer?.containerSize = NSSize(
            width: CGFloat.greatestFiniteMagnitude, height: .greatestFiniteMagnitude)
        textView.textContainer?.lineFragmentPadding = 0
        textView.setAccessibilityLabel("Text of \(editor.path)")

        let scroll = EditorScrollView()
        scroll.documentView = textView
        scroll.drawsBackground = false
        scroll.borderType = .noBorder
        scroll.hasVerticalScroller = true
        scroll.hasHorizontalScroller = true
        scroll.autohidesScrollers = true
        // No tints: the ruler only numbers the lines.
        let ruler = EditorLineRuler(textView: textView)
        // A row cut by the card's top edge keeps its number inside the ruler, not over the file's title row.
        ruler.clipsToBounds = true
        scroll.verticalRulerView = ruler
        scroll.hasVerticalRuler = true
        scroll.rulersVisible = true

        controller.scrollView = scroll
        controller.textView = textView
        controller.ruler = ruler
        textView.delegate = controller
        textView.controller = controller
        // The ruler draws the numbers of the lines on screen: it redraws with every scroll.
        let clip = scroll.contentView
        clip.postsBoundsChangedNotifications = true
        NotificationCenter.default.addObserver(
            controller, selector: #selector(EditorTextController.scrolled), name: NSView.boundsDidChangeNotification,
            object: clip)

        session.editorScrollView = scroll
        session.editorTextView = textView
        session.editorTextDelegate = controller
        return controller
    }

    @objc private func scrolled() {
        ruler?.needsDisplay = true
    }

    /// The host's update: a new code font size restyles the text, Wrap Lines (`wraps`) resizes it; a new load
    /// (`loadID`) puts its text in.
    func show(loadID: Int, fontSize: Double, wraps: Bool) {
        DiffLayout.use(fontSize)
        if shownFontSize != fontSize { applyFontSize(fontSize) }
        if shownWraps != wraps { applyWrap(wraps) }
        guard shownLoadID != loadID, let editor = session?.editor, editor.loadID == loadID,
              case .loaded(.text(let text)) = editor.content
        else { return }
        load(text, loadID: loadID)
    }

    /// Replaces the whole text with a load's (open, Reload, a silent reload): no edit, the undo history cleared, the
    /// caret kept where it was (within the new text).
    private func load(_ text: String, loadID: Int) {
        guard let textView, let storage = textView.textStorage else { return }
        let caret = textView.selectedRange().location
        isSyncing = true
        storage.beginEditing()
        storage.setAttributedString(NSAttributedString(string: text, attributes: Self.attributes))
        storage.endEditing()
        isSyncing = false
        textView.setSelectedRange(NSRange(location: min(caret, storage.length), length: 0))
        // The next typing starts a new undo group, not one of the cleared history.
        textView.breakUndoCoalescing()
        undoManager.removeAllActions()
        pendingEdit = nil
        keyStart = nil
        lastEdit = nil
        shownLoadID = loadID
        ruler?.textChanged(from: 0)
        ruler?.lineCount = Self.lineBreaks(in: storage.mutableString) + 1
        ruler?.needsDisplay = true
        if let session { UITiming.content(session.fileDetail) }
        scheduleColours(debounced: false)
    }

    /// A new code font size: the text, the typing and the ruler's width take it; the colours are scanned again.
    private func applyFontSize(_ size: Double) {
        shownFontSize = size
        guard let textView, let storage = textView.textStorage else { return }
        let attributes = Self.attributes
        textView.font = attributes[.font] as? NSFont
        textView.defaultParagraphStyle = attributes[.paragraphStyle] as? NSParagraphStyle
        textView.typingAttributes = attributes
        if storage.length > 0 {
            isSyncing = true
            storage.beginEditing()
            let whole = NSRange(location: 0, length: storage.length)
            storage.setAttributes(attributes, range: whole)
            storage.endEditing()
            isSyncing = false
            scheduleColours(debounced: false)
        }
        ruler?.fitThickness()
        ruler?.needsDisplay = true
    }

    /// Wrap Lines on: the text view is as wide as the scroll view's visible text (`EditorScrollView.wrapsText` keeps
    /// it so), its container follows it and the lines wrap there, with no horizontal scroller; the ruler numbers the
    /// first row of each line. Off: the unbounded container, the view growing sideways with its longest line.
    private func applyWrap(_ wraps: Bool) {
        shownWraps = wraps
        guard let textView, let scroll = scrollView, let container = textView.textContainer else { return }
        textView.isHorizontallyResizable = !wraps
        container.widthTracksTextView = wraps
        scroll.hasHorizontalScroller = !wraps
        scroll.wrapsText = wraps
        if wraps {
            let clip = scroll.contentView
            clip.scroll(to: NSPoint(x: -clip.contentInsets.left, y: clip.bounds.minY))
            scroll.reflectScrolledClipView(clip)
            let width = max(0, textView.frame.width - 2 * textView.textContainerInset.width)
            container.containerSize = NSSize(width: width, height: .greatestFiniteMagnitude)
        } else {
            container.containerSize = NSSize(width: CGFloat.greatestFiniteMagnitude, height: .greatestFiniteMagnitude)
            textView.sizeToFit()
        }
        ruler?.wraps = wraps
    }

    // MARK: Find bar

    /// Hides the find bar when it shows; false when it does not.
    @discardableResult
    func hideFindBar() -> Bool {
        guard let textView, scrollView?.isFindBarVisible == true else { return false }
        let item = NSMenuItem()
        item.tag = NSTextFinder.Action.hideFindInterface.rawValue
        textView.performTextFinderAction(item)
        return true
    }

    /// Esc in the text with the find bar hidden: leaves the file, asking first when it is dirty.
    func closeFileAsking() {
        session?.closeFileAsking()
    }

    /// The close button's Esc while the find bar shows: hides the bar instead of closing the editor.
    func hideFindBarOnEscape() -> Bool {
        guard let event = NSApp.currentEvent, event.type == .keyDown, event.keyCode == 53 else { return false }
        return hideFindBar()
    }

    // MARK: Editing

    func undoManager(for view: NSTextView) -> UndoManager? {
        undoManager
    }

    func textView(_ textView: NSTextView, shouldChangeTextIn range: NSRange, replacementString: String?) -> Bool {
        guard !isSyncing else { return true }
        #if DEBUG || HISTQ_PERF
        if keyStart == nil { keyStart = DispatchTime.now().uptimeNanoseconds }
        #endif
        // Attributes only: no line break changes.
        guard let replacementString, let storage = textView.textStorage else { return true }
        guard pendingEdit == nil else {
            pendingEdit = .many
            return true
        }
        let start = max(0, range.location - 1)
        let oldBreaks = Self.lineBreaks(in: storage.mutableString,
                                        range: NSRange(location: start, length: NSMaxRange(range) - start))
        pendingEdit = .one(start: start, newEnd: range.location + (replacementString as NSString).length,
                           oldBreaks: oldBreaks)
        return true
    }

    func textDidChange(_ notification: Notification) {
        guard !isSyncing, let textView, let storage = textView.textStorage else { return }
        let text = storage.mutableString
        if let ruler {
            if case .one(let start, let newEnd, let oldBreaks)? = pendingEdit, newEnd <= text.length {
                let newBreaks = Self.lineBreaks(in: text, range: NSRange(location: start, length: newEnd - start))
                ruler.lineCount = max(1, ruler.lineCount + newBreaks - oldBreaks)
                ruler.textChanged(from: start)
            } else {
                ruler.lineCount = Self.lineBreaks(in: text) + 1
                ruler.textChanged(from: 0)
            }
            ruler.needsDisplay = true
        }
        pendingEdit = nil
        session?.editorDidChange()
        #if DEBUG || HISTQ_PERF
        let now = DispatchTime.now().uptimeNanoseconds
        if let keyStart {
            UITiming.probe("editor-key", String(format: "%.1f", Double(now &- keyStart) / 1_000_000))
        }
        keyStart = nil
        lastEdit = now
        #endif
        scheduleColours(debounced: true)
    }

    // MARK: Colours

    /// Scans the whole text for syntax colours off the main actor (after `colourDelay` when typing) and applies them;
    /// dropped when a newer load or edit came meanwhile. Plain text has none.
    private func scheduleColours(debounced: Bool) {
        colourTask?.cancel()
        colourGeneration &+= 1
        guard let language else { return }
        let generation = colourGeneration
        #if DEBUG || HISTQ_PERF
        let since = debounced ? lastEdit : DispatchTime.now().uptimeNanoseconds
        #else
        let since: UInt64? = nil
        #endif
        colourTask = Task { [weak self] in
            if debounced {
                guard (try? await Task.sleep(for: Self.colourDelay)) != nil else { return }
            }
            // The text as it is once typing paused: one copy per scan, never per key.
            guard let text = self?.currentText(generation) else { return }
            let runs = await EditorColours.runs(of: text, language: language)
            guard !Task.isCancelled else { return }
            self?.applyColours(runs, generation: generation, since: since, debounced: debounced)
        }
    }

    private func currentText(_ generation: Int) -> String? {
        guard generation == colourGeneration, let textView else { return nil }
        return textView.string
    }

    /// Colours the text with `runs` (they cover it whole, so no reset of the whole range is needed: that is slow on a
    /// text with many runs), as text storage attributes: no undo, no selection change, no edit.
    private func applyColours(_ runs: [EditorColours.Run], generation: Int, since: UInt64?, debounced: Bool) {
        guard generation == colourGeneration, let textView, let storage = textView.textStorage,
              !textView.hasMarkedText(), (runs.last.map { NSMaxRange($0.range) } ?? 0) == storage.length
        else { return }
        storage.beginEditing()
        for run in runs {
            storage.addAttribute(.foregroundColor, value: SyntaxColors.color(run.kind), range: run.range)
        }
        storage.endEditing()
        #if DEBUG || HISTQ_PERF
        if let since {
            let ms = Double(DispatchTime.now().uptimeNanoseconds &- since) / 1_000_000
            UITiming.probe("editor-colour", (debounced ? "key " : "load ") + String(format: "%.1f", ms)
                + " runs=\(runs.count)")
        }
        #endif
    }

    // MARK: Line count

    /// The line breaks in `range` of `text` (all of it by default), as the text view breaks lines: LF, a CR not
    /// followed by an LF (looked up past the range's end too), CRLF once, U+2028, U+2029 and U+0085.
    static func lineBreaks(in text: NSString, range: NSRange? = nil) -> Int {
        let range = range ?? NSRange(location: 0, length: text.length)
        guard range.length > 0 else { return 0 }
        let peeks = NSMaxRange(range) < text.length
        var characters = [unichar](repeating: 0, count: range.length + (peeks ? 1 : 0))
        text.getCharacters(&characters, range: NSRange(location: range.location, length: characters.count))
        var count = 0
        for index in 0 ..< range.length {
            switch characters[index] {
            case 0x0A, 0x2028, 0x2029, 0x85: count += 1
            case 0x0D where index + 1 >= characters.count || characters[index + 1] != 0x0A: count += 1
            default: break
            }
        }
        return count
    }
}

#if DEBUG
extension EditorTextController {
    /// DEBUG `-HistqEditorRun`: the view holds the text of the editor's current load (its `content` line is logged).
    var debugShowsCurrentLoad: Bool {
        guard let editor = session?.editor, textView != nil else { return false }
        return shownLoadID == editor.loadID
    }

    /// DEBUG `-HistqEditorRun`'s `append:<text>`: inserts `text` at the end through the text view's `insertText`, so
    /// the real edit path runs (`shouldChangeTextIn`, `textDidChange`, `editorDidChange`). False before the view holds
    /// the current load's text.
    func debugAppend(_ text: String) -> Bool {
        guard debugShowsCurrentLoad, let textView else { return false }
        let end = (textView.string as NSString).length
        textView.setSelectedRange(NSRange(location: end, length: 0))
        textView.insertText(text, replacementRange: NSRange(location: end, length: 0))
        return true
    }
}
#endif

/// The editor's text view: Esc closes the find bar when it shows, else leaves the file as the close button does
/// (asks first when dirty); Esc during IME composition goes to the input method. It takes the keyboard when it is put
/// on screen (the Edit tab, a Reload), never in a hidden tab.
final class EditorTextView: NSTextView {
    weak var controller: EditorTextController?

    override func cancelOperation(_ sender: Any?) {
        if hasMarkedText() { return super.cancelOperation(sender) }
        guard let controller, !controller.hideFindBar() else { return }
        controller.closeFileAsking()
    }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        // No `focus` timing line: that one is `WindowModel.focusShownTab`'s, once per tab switch.
        guard let window, !isHiddenOrHasHiddenAncestor, window.firstResponder !== self else { return }
        window.makeFirstResponder(self)
    }
}

/// The editor's scroll view: tells its host when the find bar shows or hides (Esc then closes the bar, not the
/// editor). A bar that hides with the keyboard in it (Esc, Done, Cmd-F) gives the keyboard back to the text view, never
/// to the next view of the window: right away, after SwiftUI applies the change (next turns) and once the bar leaves
/// the view, unless the user clicked since. A click in the bar (Done) counts as the keyboard in the editor, even when
/// AppKit already gave it to the next view. Esc in the bar is taken by a local monitor, live while the bar shows: it
/// hides the bar and puts the keyboard back in the text before AppKit can move it to another view. With Wrap Lines on,
/// it keeps the text view as wide as the text's visible area.
final class EditorScrollView: NSScrollView {
    var onFindBarChange: ((Bool) -> Void)?
    /// Wrap Lines: the text view's width follows the visible area right of the ruler (`tile`).
    var wrapsText = false {
        didSet { if wrapsText != oldValue { tile() } }
    }
    /// When the bar hid with the keyboard in the editor (text, bar, or nowhere); nil when it was in another view.
    private var keyboardHideTime: TimeInterval?
    /// The Esc monitor, while the find bar shows in a window.
    private var escapeMonitor: Any?

    /// How long after a hide the text still takes the keyboard back.
    private static let refocusWindow: TimeInterval = 1

    override var isFindBarVisible: Bool {
        willSet {
            let hiding = isFindBarVisible && !newValue
            // A click in the bar (Done) may hand the keyboard to the next view before this: the editor's hide too.
            let inEditor = hiding && (keyboardInEditor || currentEventIsFindBarClick)
            keyboardHideTime = inEditor ? ProcessInfo.processInfo.systemUptime : nil
        }
        didSet {
            if oldValue != isFindBarVisible { onFindBarChange?(isFindBarVisible) }
            updateEscapeMonitor()
            guard keyboardHideTime != nil else { return }
            takeKeyboardBack()
            // SwiftUI applies `findBarShown` after this: take it back after that turn and the next one too.
            Task { @MainActor [weak self] in
                self?.takeKeyboardBack()
                DispatchQueue.main.async { [weak self] in self?.takeKeyboardBack() }
            }
        }
    }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        updateEscapeMonitor()
    }

    /// The line-number ruler floats over the clip view, which keeps the text clear of it with a left content inset.
    /// AppKit does not move a clip that sat at its left edge when that inset changes (the first layout, a wider ruler):
    /// the text's first columns would hide under the numbers. Keep such a clip at its new edge. With Wrap Lines on, the
    /// text view takes the visible width (a resize or a wider ruler wraps the lines again), and the ruler redraws: a
    /// resize moves the rows its numbers sit on.
    override func tile() {
        let clip = contentView
        let atLeftEdge = abs(clip.bounds.minX + clip.contentInsets.left) < 0.5
        super.tile()
        if wrapsText, let text = documentView {
            let width = max(0, clip.bounds.width - clip.contentInsets.left - clip.contentInsets.right)
            if abs(text.frame.width - width) >= 0.5 {
                text.setFrameSize(NSSize(width: width, height: text.frame.height))
            }
            verticalRulerView?.needsDisplay = true
        }
        let edge = -clip.contentInsets.left
        if atLeftEdge, abs(clip.bounds.minX - edge) >= 0.5 {
            clip.scroll(to: NSPoint(x: edge, y: clip.bounds.minY))
            reflectScrolledClipView(clip)
        }
    }

    /// The bar leaving the view (after its hide animation) may move the keyboard on: take it back after that.
    override func willRemoveSubview(_ subview: NSView) {
        super.willRemoveSubview(subview)
        guard keyboardHideTime != nil, subview === findBarView else { return }
        DispatchQueue.main.async { [weak self] in self?.takeKeyboardBack() }
    }

    /// The window's first responder is in the editor: its text, its find bar, or the window itself / none.
    private var keyboardInEditor: Bool {
        guard let window else { return false }
        guard let responder = window.firstResponder, responder !== window else { return true }
        return responder === documentView || isInFindBar(responder)
    }

    /// The event being handled is a left click in the window's find bar (its Done button or close control).
    private var currentEventIsFindBarClick: Bool {
        guard let window, let event = NSApp.currentEvent, event.window === window,
              event.type == .leftMouseDown || event.type == .leftMouseUp
        else { return false }
        if let bar = findBarView { return bar.bounds.contains(bar.convert(event.locationInWindow, from: nil)) }
        let point = convert(event.locationInWindow, from: nil)
        return bounds.contains(point) && !contentView.frame.contains(point)
    }

    /// After a hide that had the keyboard in the editor: the text takes it back, unless the hide is old or the user
    /// clicked since (a click elsewhere keeps its view).
    private func takeKeyboardBack() {
        guard let hideTime = keyboardHideTime else { return }
        if ProcessInfo.processInfo.systemUptime - hideTime > Self.refocusWindow { keyboardHideTime = nil; return }
        if let event = NSApp.currentEvent, event.timestamp > hideTime,
           [.leftMouseDown, .rightMouseDown, .otherMouseDown].contains(event.type)
        {
            keyboardHideTime = nil
            return
        }
        giveKeyboardToText()
    }

    /// The responder is a view of the find bar, or the field editor of one.
    private func isInFindBar(_ responder: NSResponder) -> Bool {
        guard let view = responder as? NSView else { return false }
        if isInFindBar(view: view) { return true }
        if let editor = view as? NSTextView, editor.isFieldEditor, let field = editor.delegate as? NSView {
            return isInFindBar(view: field)
        }
        return false
    }

    private func isInFindBar(view: NSView) -> Bool {
        if let bar = findBarView { return view.isDescendant(of: bar) }
        return view.isDescendant(of: self) && !view.isDescendant(of: contentView)
    }

    /// Installs the Esc monitor while the find bar shows in a window, removes it otherwise.
    private func updateEscapeMonitor() {
        let wanted = isFindBarVisible && window != nil
        guard wanted != (escapeMonitor != nil) else { return }
        if let escapeMonitor { NSEvent.removeMonitor(escapeMonitor) }
        escapeMonitor = nil
        guard wanted else { return }
        escapeMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
            let isEscape = event.keyCode == 53
                && event.modifierFlags.intersection(.deviceIndependentFlagsMask)
                    .subtracting([.capsLock, .numericPad, .function]).isEmpty
            let eventWindow = event.window
            let taken = MainActor.assumeIsolated {
                guard isEscape, let self else { return false }
                return self.escapeInFindBar(eventWindow)
            }
            return taken ? nil : event
        }
    }

    /// Esc with the keyboard in the find bar: hides the bar (only: the editor stays) and gives the text the keyboard.
    /// Esc during an input method's composition in the search field goes to the input method instead.
    private func escapeInFindBar(_ eventWindow: NSWindow?) -> Bool {
        guard let window, eventWindow === window, isFindBarVisible, !isHiddenOrHasHiddenAncestor,
              let responder = window.firstResponder, isInFindBar(responder),
              (responder as? NSTextInputClient)?.hasMarkedText() != true,
              let text = documentView as? EditorTextView, text.controller?.hideFindBar() == true
        else { return false }
        giveKeyboardToText()
        return true
    }

    /// The text view takes the keyboard, when it shows in a window and does not have it already.
    private func giveKeyboardToText() {
        guard let window, !isHiddenOrHasHiddenAncestor, let text = documentView as? EditorTextView,
              window.firstResponder !== text
        else { return }
        window.makeFirstResponder(text)
    }
}

/// The editor's line numbers: Output's ruler (fixed lines) while Wrap Lines is off. With it on, a line can take more
/// than one row, so the numbers follow the layout manager's line fragments on screen: one on the first row of each
/// line, none on the rows it wraps onto, and the last number on the empty row after a final line break. The line of the
/// first row on screen is counted from a kept anchor (a line start and the line breaks before it), so a redraw counts
/// only the text between the two, not the file from its top.
final class EditorLineRuler: ConflictLineRuler {
    var wraps = false {
        didSet { if wraps != oldValue { needsDisplay = true } }
    }

    /// A line start (UTF-16 offset) and the line breaks before it; nil until counted, and after an edit before it.
    private var anchor: (location: Int, breaks: Int)?

    /// The text changed from `location` on: an anchor at or after it is dropped.
    func textChanged(from location: Int) {
        if let anchor, location <= anchor.location { self.anchor = nil }
    }

    override func drawHashMarksAndLabels(in rect: NSRect) {
        guard wraps else { return super.drawHashMarksAndLabels(in: rect) }
        guard let textView, let layoutManager = textView.layoutManager, let container = textView.textContainer,
              let text = textView.textStorage?.mutableString, lineCount > 0
        else { return }
        let origin = textView.textContainerOrigin
        let visible = textView.visibleRect.offsetBy(dx: -origin.x, dy: -origin.y)
        let numberHeight = DiffLayout.numberFont.boundingRectForFont.height
        let attributes = Self.attributes
        /// Draws `number` level with `row`, a line fragment in the container's coordinates.
        func draw(_ number: Int, at row: NSRect) {
            let y = convert(NSPoint(x: 0, y: row.minY + origin.y), from: textView).y
            NSString(string: "\(number)").draw(
                in: NSRect(x: 0, y: y + (row.height - numberHeight) / 2, width: ruleThickness - 8, height: row.height),
                withAttributes: attributes)
        }
        let glyphs = layoutManager.glyphRange(forBoundingRect: visible, in: container)
        var number: Int?
        if glyphs.length > 0 {
            layoutManager.enumerateLineFragments(forGlyphRange: glyphs) { row, _, _, rowGlyphs, _ in
                let start = layoutManager.characterIndexForGlyph(at: rowGlyphs.location)
                guard start == 0 || Self.isLineBreak(text.character(at: start - 1)) else { return }
                let line = number.map { $0 + 1 } ?? self.breaks(before: start, in: text) + 1
                number = line
                draw(line, at: row)
            }
        }
        // The empty row after a final line break (or of an empty file) is not a line fragment.
        let extra = layoutManager.extraLineFragmentRect
        if layoutManager.extraLineFragmentTextContainer != nil, extra.maxY > visible.minY, extra.minY < visible.maxY {
            draw(lineCount, at: extra)
        }
    }

    /// The line breaks before `location` (a line start), counted from the anchor, which then moves there.
    private func breaks(before location: Int, in text: NSString) -> Int {
        let breaks = if let anchor, location >= anchor.location {
            anchor.breaks + EditorTextController.lineBreaks(
                in: text, range: NSRange(location: anchor.location, length: location - anchor.location))
        } else if let anchor {
            anchor.breaks - EditorTextController.lineBreaks(
                in: text, range: NSRange(location: location, length: anchor.location - location))
        } else {
            EditorTextController.lineBreaks(in: text, range: NSRange(location: 0, length: location))
        }
        anchor = (location, breaks)
        return breaks
    }

    /// A character the text view breaks lines at, as `EditorTextController.lineBreaks` counts them (a CR's LF is
    /// never the last character before a row).
    private static func isLineBreak(_ character: unichar) -> Bool {
        switch character {
        case 0x0A, 0x0D, 0x2028, 0x2029, 0x85: true
        default: false
        }
    }
}

/// The editor's syntax colours: the whole text scanned line by line with `SyntaxScanner`, off the main actor.
enum EditorColours {
    /// A colour run: UTF-16 range of the text and its token kind. The runs of a scan cover the whole text in order,
    /// plain gaps (and the line breaks) included, neighbours of one kind merged.
    struct Run: Sendable {
        var range: NSRange
        let kind: TokenKind
    }

    /// `text`'s runs. Lines split at LF only (a CRLF's CR is left out of the scan, kept in the runs); a cancelled
    /// task gets no runs.
    @concurrent
    nonisolated static func runs(of text: String, language: Language) async -> [Run] {
        let units = Array(text.utf16)
        var runs: [Run] = []
        func add(_ location: Int, _ length: Int, _ kind: TokenKind) {
            guard length > 0 else { return }
            if let last = runs.last, last.kind == kind, NSMaxRange(last.range) == location {
                runs[runs.count - 1].range.length += length
            } else {
                runs.append(Run(range: NSRange(location: location, length: length), kind: kind))
            }
        }
        var state = ScanState()
        var lineStart = 0
        var lineIndex = 0
        while lineStart <= units.count {
            var lineEnd = lineStart
            while lineEnd < units.count, units[lineEnd] != 0x0A { lineEnd += 1 }
            var textEnd = lineEnd
            if textEnd > lineStart, units[textEnd - 1] == 0x0D { textEnd -= 1 }
            let line = String(decoding: units[lineStart ..< textEnd], as: UTF16.self)
            var position = lineStart
            for token in SyntaxScanner.scan(line: line, state: &state, language: language) where token.kind != .plain {
                let start = lineStart + token.range.location
                guard start >= position, start + token.range.length <= textEnd else { continue }
                add(position, start - position, .plain)
                add(start, token.range.length, token.kind)
                position = start + token.range.length
            }
            // The rest of the line and its line break.
            let next = min(lineEnd + 1, units.count)
            add(position, next - position, .plain)
            if lineEnd >= units.count { break }
            lineStart = next
            lineIndex += 1
            if lineIndex % 4096 == 0, Task.isCancelled { return [] }
        }
        return runs
    }
}
