// The file editor's state in a tab: which WIP files can be edited, opening one (its text read off the main actor),
// the Edit and diff tabs over one kept buffer, dirty tracking, Save (a byte-exact write, never staged), Reload and
// Keep Mine, and the disk check after each status read that tells an outside change from Histq's own save.
import AppKit
import HistqCore

/// The file editor of one WIP file (`RepoSession.editor`): the small state its views observe. The text itself lives in
/// the text view (`RepoSession.editorTextView`) from the load on, never copied back here.
struct FileEditor: Equatable {
    /// The file changed on disk since the editor loaded or saved it, while its buffer is unsaved (Reload / Keep Mine),
    /// or it is gone (Copy Text / Close: nothing is made again).
    enum DiskChange: Equatable, Sendable {
        case modified
        case deleted
    }

    let path: String
    /// `.loading` until the read is in (and again on Reload); then the text, or why the file can't be edited.
    var content: Loadable<EditorContent> = .loading
    /// Changes with every load and Reload: the text view takes `content`'s text then, and clears its undo history.
    var loadID = 0
    /// The buffer differs from the file loaded or last saved: set on every edit at once, cleared only by a byte
    /// compare.
    var isDirty = false
    /// The Edit tab shows; false while Diff, Split or Full file shows over the kept buffer.
    var showsEditor = true
    var diskChange: DiskChange?
    /// A save in flight: Save is greyed, the disk check waits, leaving waits.
    var saving = false
    /// The last failed save, shown in the editor's card.
    var error: String?
}

/// What the editor loaded: the text to edit, or why the file can't be edited (a notice with Back to Diff).
enum EditorContent: Equatable, Sendable {
    case text(String)
    case refused(EditableFile.Refusal)
}

/// How a file editor save ended: written, refused because the file changed or went on disk (`diskChange` says
/// which), or failed (`error` says why).
enum EditorSaveOutcome: Sendable {
    case saved
    case blocked
    case failed
}

/// The file editor's save refused before writing: the file changed or went on disk since the editor's base.
struct EditorSaveRefused: LocalizedError, Sendable {
    let change: FileEditor.DiskChange

    var errorDescription: String? {
        switch change {
        case .modified: "The file changed on disk."
        case .deleted: "The file was deleted on disk."
        }
    }
}

/// A worktree file read for editing: its bytes (the editor's base) and its text.
struct EditorFile: Sendable {
    let data: Data
    let text: EditableText
}

extension RepoSession {
    // MARK: Opening

    /// Whether `target` can open in the file editor: a WIP file that is not conflicted (its target or its status
    /// entry), not deleted (its target or its working tree side), not a submodule, an image or an untracked folder.
    func canEdit(_ target: FileTarget) -> Bool {
        let file = target.file
        guard target.source == .wip, !target.isConflict, file.kind != .conflicted, file.kind != .deleted,
              !file.isSubmodule, !target.isImage, !target.path.hasSuffix("/")
        else { return false }
        guard let status = self.status.value else { return true }
        if status.conflicted.contains(where: { $0.path == target.path }) { return false }
        let entry = status.entries.first { $0.path == target.path }
        return entry?.worktree != .deleted && entry?.isSubmodule != true
    }

    /// `target` is the edited file: the WIP's file at the editor's path, never its conflict (a commit's or a stash's
    /// file of the same path is another file).
    func isEditedFile(_ target: FileTarget) -> Bool {
        target.source == .wip && !target.isConflict && target.path == editor?.path
    }

    /// Opens `path` of the working tree in the file editor (the Edit tab, Edit File…): the editor's placeholder shows
    /// in this call, its text is read off the main actor. The file already being edited shows its kept buffer again.
    /// A path that can't be edited (`canEdit`) does nothing.
    func openEditor(path: String) {
        if editor?.path == path, let openFile, isEditedFile(openFile) { return startEditing() }
        // The open row of that file (staged or unstaged) when it shows, else the row the WIP panel would open.
        let target = if let openFile, openFile.source == .wip, !openFile.isConflict, openFile.path == path {
            openFile
        } else {
            wipFileTarget(path)
        }
        guard canEdit(target) else { return }
        selectFile(target, returnTool: target == openFile ? returnTool : nil, editing: true)
    }

    /// `selectFile(_:editing: true)`'s part: shows the kept buffer of `path`, or makes the editor for it and reads it.
    /// A buffer that could not be read (a refusal) is read again.
    func beginEditing(_ path: String) {
        if var editor, editor.path == path {
            if case .loaded(.refused) = editor.content { return reloadEditor(showing: true) }
            if !editor.showsEditor {
                editor.showsEditor = true
                self.editor = editor
            }
            return
        }
        if editor != nil { dropEditor() }
        editor = FileEditor(path: path)
        loadEditor()
    }

    /// The Edit tab over the kept buffer: no prompt, no reload (a refusal is read again).
    func startEditing() {
        guard let editor else { return }
        beginEditing(editor.path)
    }

    /// A diff tab (Diff, Split, Full file) over the kept buffer: no prompt; the diff of the file on disk is read again.
    func showDiff() {
        guard var editor, editor.showsEditor else { return }
        editor.showsEditor = false
        self.editor = editor
        startFileLoad()
    }

    /// Drops the editor with its buffer, its text view and every read in flight (leaving the file).
    func dropEditor() {
        editorLoadTask?.cancel()
        editorLoadTask = nil
        editorDiskTask?.cancel()
        editorDiskTask = nil
        editorDirtyCheck?.cancel()
        editorDirtyCheck = nil
        editorDiskGeneration &+= 1
        editorBase = Data()
        editorCodec = nil
        editorScrollView = nil
        editorTextView = nil
        editorTextDelegate = nil
        editor = nil
    }

    // MARK: Loading

    /// The notice's Reload: drops the buffer (its unsaved text too) and reads the file again, placeholder first.
    func reloadEditor() {
        reloadEditor(showing: false)
    }

    private func reloadEditor(showing: Bool) {
        guard var editor, !editor.saving else { return }
        if showing { editor.showsEditor = true }
        editor.content = .loading
        editor.isDirty = false
        editor.diskChange = nil
        editor.error = nil
        self.editor = editor
        loadEditor(followsStatus: true)
    }

    /// Reads the editor's file off the main actor into `content` (`loadID` + 1). `followsStatus` (Reload): the status
    /// branch runs again once the text is in, so a path turned unmerged goes to the conflict editor now it is clean.
    private func loadEditor(followsStatus: Bool = false) {
        guard let editor else { return }
        editorLoadTask?.cancel()
        editorDiskTask?.cancel()
        editorDirtyCheck?.cancel()
        editorDiskGeneration &+= 1
        let path = editor.path
        let loadID = editor.loadID
        let cwd = url
        editorLoadTask = Task { [weak self] in
            let read = await Self.readEditableFile(path, cwd: cwd)
            guard let self, !Task.isCancelled, var editor = self.editor, editor.path == path, editor.loadID == loadID
            else { return }
            applyEditorRead(read, to: &editor)
            self.editor = editor
            if followsStatus { followStatusForEditor(checksDisk: false) }
        }
    }

    /// Puts a read into the editor as a new load: its text (the new base) or its refusal; nothing unsaved after it.
    private func applyEditorRead(_ read: Result<EditorFile, EditableFile.Refusal>, to editor: inout FileEditor) {
        switch read {
        case .success(let file):
            editorBase = file.data
            editorCodec = file.text
            editor.content = .loaded(.text(file.text.text))
        case .failure(let refusal):
            editorBase = Data()
            editorCodec = nil
            editor.content = .loaded(.refused(refusal))
        }
        editor.loadID &+= 1
        editor.isDirty = false
        editor.diskChange = nil
        editor.error = nil
        editorDiskGeneration &+= 1
        editorDirtyCheck?.cancel()
    }

    // MARK: Editing

    /// Every user edit of the buffer (the text view's delegate): unsaved at once, so the guards, Save and quit see it
    /// without waiting. Whether it went back to the saved bytes (an undo) is checked once typing pauses.
    func editorDidChange() {
        editorDiskGeneration &+= 1
        guard let editor else { return }
        if !editor.isDirty { self.editor?.isDirty = true }
        editorDirtyCheck?.cancel()
        editorDirtyCheck = Task { [weak self] in
            try? await Task.sleep(for: .milliseconds(300))
            guard !Task.isCancelled else { return }
            self?.recheckEditorDirty()
        }
    }

    /// Clears `isDirty` when the buffer, as it is now, encodes to the saved bytes. Runs on the main actor when the
    /// debounce fires and reads the text view then, so a key typed after it was scheduled is never cleared.
    private func recheckEditorDirty() {
        guard let editor, editor.isDirty, !editor.saving, let textView = editorTextView, let codec = editorCodec
        else { return }
        if codec.encode(textView.string) == editorBase { self.editor?.isDirty = false }
    }

    /// The notice's Copy Text (a file deleted on disk): the buffer to the clipboard.
    func copyEditorText() {
        guard let textView = editorTextView else { return }
        RepoMenus.copy(textView.string)
    }

    // MARK: Saving

    /// Save (the card's button, Cmd-S, the leave prompt's Save): writes the buffer's bytes to the file if the file is
    /// still what the editor loaded or last saved; a change on disk sets `diskChange` instead (Reload / Keep Mine). The
    /// buffer, its caret and its undo history stay. Nil when nothing started: nothing unsaved, a save in flight, or
    /// the file deleted on disk.
    @discardableResult
    func saveEditor() -> Task<EditorSaveOutcome, Never>? {
        startEditorSave(keepingMine: false)
    }

    /// The notice's Keep Mine: saves the buffer over the change on disk.
    @discardableResult
    func keepMine() -> Task<EditorSaveOutcome, Never>? {
        guard editor?.diskChange == .modified else { return nil }
        return startEditorSave(keepingMine: true)
    }

    private func startEditorSave(keepingMine: Bool) -> Task<EditorSaveOutcome, Never>? {
        guard var editor, !editor.saving, editor.isDirty || keepingMine, editor.diskChange != .deleted,
              case .loaded(.text) = editor.content, let textView = editorTextView, let codec = editorCodec
        else { return nil }
        // The leave prompt's way out, if this is its Save: taken now, applied only if the write succeeds.
        let leave = takePendingLeave()
        let content = codec.encode(textView.string)
        let path = editor.path
        let loadID = editor.loadID
        let write = Write.saveFile(path: path, content: content, base: keepingMine ? nil : editorBase)
        editor.saving = true
        editor.error = nil
        self.editor = editor
        // A disk check in flight compares with the old base.
        editorDiskTask?.cancel()
        editorDiskGeneration &+= 1
        let endOperation = beginOperation("Saving \((path as NSString).lastPathComponent)")
        return Task { [weak self] in
            defer { endOperation() }
            guard let self else { return .failed }
            let outcome: EditorSaveOutcome
            var change: FileEditor.DiskChange?
            var message: String?
            do {
                try await perform(write)
                outcome = .saved
            } catch let refused as EditorSaveRefused {
                change = refused.change
                outcome = .blocked
            } catch {
                message = Self.message(for: error)
                outcome = .failed
            }
            // The editor's own token: a newer load (Reload) or another file's editor ignores this end.
            if var editor = self.editor, editor.path == path, editor.loadID == loadID {
                editor.saving = false
                switch outcome {
                case .saved:
                    editorBase = content
                    // Typed during the write: still unsaved.
                    editor.isDirty = editorTextView.map { codec.encode($0.string) != content } ?? false
                    editor.diskChange = nil
                case .blocked:
                    editor.diskChange = change
                case .failed:
                    editor.error = message
                }
                self.editor = editor
                editorDiskGeneration &+= 1
            }
            endEditorWrite(leave, saved: outcome == .saved)
            // Its own refresh (after a failure too) skipped the editor while it saved.
            followStatusForEditor(checksDisk: false)
            return outcome
        }
    }

    // MARK: Disk check

    /// After a status read: reads the edited file off the main actor and compares it with the editor's base. The same
    /// bytes (Histq's own save among them) change nothing; other bytes reload a clean buffer silently, and mark a dirty
    /// one changed (`diskChange`); a missing file marks it deleted. Skipped while the editor saves or loads.
    func checkEditorDisk() {
        guard let editor, !editor.saving, case .loaded(.text) = editor.content else { return }
        editorDiskTask?.cancel()
        editorDiskGeneration &+= 1
        let generation = editorDiskGeneration
        let path = editor.path
        let loadID = editor.loadID
        let base = editorBase
        let cwd = url
        editorDiskTask = Task { [weak self] in
            let read = await Self.readEditableFile(path, cwd: cwd)
            guard !Task.isCancelled,
                  self?.noteDiskRead(read, path: path, loadID: loadID, base: base, generation: generation) == true
            else { return }
            // A clean buffer: the disk is read again here (not the check's bytes), and the text replaced only if the
            // buffer is still clean when it is in.
            let again = await Self.readEditableFile(path, cwd: cwd)
            guard !Task.isCancelled else { return }
            self?.noteDiskRead(again, path: path, loadID: loadID, base: base, generation: generation, replaces: true)
        }
    }

    /// Decides what a disk read does, on the main actor when it is in. Dropped when the editor saved, loaded or left
    /// since. A dirty buffer is never replaced: it gets `diskChange`. A clean one is replaced only when no edit or
    /// newer check came since (`generation`); returns true when it should be read again for that (`replaces` false).
    @discardableResult
    private func noteDiskRead(
        _ read: Result<EditorFile, EditableFile.Refusal>, path: String, loadID: Int, base: Data, generation: Int,
        replaces: Bool = false
    ) -> Bool {
        guard var editor, editor.path == path, editor.loadID == loadID, !editor.saving, editorBase == base else {
            return false
        }
        switch read {
        case .success(let file) where file.data == base:
            // Back to what the editor has (or never changed): no notice.
            guard editor.diskChange != nil else { return false }
            editor.diskChange = nil
        case .failure(.missing):
            guard editor.diskChange != .deleted else { return false }
            editor.diskChange = .deleted
        default:
            if editor.isDirty {
                guard editor.diskChange != .modified else { return false }
                editor.diskChange = .modified
            } else {
                guard generation == editorDiskGeneration else { return false }
                guard replaces else { return true }
                applyEditorRead(read, to: &editor)
            }
        }
        self.editor = editor
        return false
    }

    // MARK: Reading and writing off the main actor

    /// The worktree file `path` read for editing (`EditableFile.read`, at most `fileSizeLimit` bytes), off the main
    /// actor.
    @concurrent
    nonisolated static func readEditableFile(_ path: String, cwd: URL) async
        -> Result<EditorFile, EditableFile.Refusal>
    {
        readEditable(path, cwd: cwd)
    }

    private nonisolated static func readEditable(_ path: String, cwd: URL) -> Result<EditorFile, EditableFile.Refusal> {
        do throws(EditableFile.Refusal) {
            let file = try EditableFile.read(path: path, cwd: cwd, limit: fileSizeLimit)
            return .success(EditorFile(data: file.data, text: file.text))
        } catch {
            return .failure(error)
        }
    }

    /// `Write.saveFile`'s write, in `run`'s hop: with a `base`, the file is read again and must still be those bytes;
    /// then the file and its folder must still exist (`lstat`, right before the write: `writeResolution` would make a
    /// removed folder again). Throws `EditorSaveRefused` when either check fails.
    nonisolated static func writeEditedFile(_ content: Data, to path: String, base: Data?, cwd: URL) throws {
        if let base {
            switch readEditable(path, cwd: cwd) {
            case .success(let file) where file.data == base: break
            case .failure(.missing): throw EditorSaveRefused(change: .deleted)
            default: throw EditorSaveRefused(change: .modified)
            }
        }
        let file = cwd.appending(path: path)
        guard exists(file), exists(file.deletingLastPathComponent()) else {
            throw EditorSaveRefused(change: .deleted)
        }
        try GitOperations.writeResolution(content, to: path, cwd: cwd)
    }

    /// Something is at `url` (never followed if it is a symlink).
    private nonisolated static func exists(_ url: URL) -> Bool {
        var info = stat()
        return url.withUnsafeFileSystemRepresentation { path in
            guard let path else { return false }
            return lstat(path, &info) == 0
        }
    }
}

#if DEBUG
extension RepoSession {
    /// Whether `-HistqEditorRun` already ran in this launch.
    private static var launchEditorRunDone = false

    /// DEBUG `-HistqEditorRun "<step>[;;<step>…]"` (with `-HistqSelect edit:<path>`): once per launch, once the editor
    /// shows its text, runs the steps in order through the editor's own paths; each outcome goes to `operations.txt`.
    /// `append:<text>` (typed at the end through the text view's `insertText`; `\n` is a newline), `save`
    /// (`saved` / `blocked` / `failed`), `leave:<path>` (selects that WIP file: `prompt` / `no-prompt`),
    /// `answer:save|discard|cancel` (the leave prompt's button; then the open file), `wait-file:<name>` (`waiting
    /// <name>`, then `go <name>` once that file is in the state folder, or `timeout` after 10 s), `reload` (the
    /// notice's Reload: `reloaded`), `keepmine` (`saved` / `failed`, `skipped` without a change on disk),
    /// `wait-refresh` (a status refresh and its disk check: `reloaded`, `diskChange modified|deleted`, `unchanged` or
    /// `timeout`) and `state` (after 500 ms: `editor open <path> shows=<edit|diff> dirty=<yes|no>` or `editor closed`).
    /// For QA on fixture copies only.
    func runLaunchEditor(_ spec: String) {
        guard !Self.launchEditorRunDone else { return }
        Self.launchEditorRunDone = true
        Task { [weak self] in
            guard let self else { return }
            guard editor != nil else { return RepoMenus.debugLog("editor closed") }
            guard await debugWait(until: { self.debugEditorController?.debugShowsCurrentLoad == true }) else {
                return RepoMenus.debugLog("timeout content")
            }
            // The load as the last step left it: `wait-refresh` logs `reloaded` when a newer one came since. `wait-file`
            // and `state` never move it, so a reload between the shell's change and its marker counts.
            var loadID = editor?.loadID
            for step in spec.components(separatedBy: ";;") where !step.isEmpty {
                await runEditorStep(step, since: loadID)
                if !step.hasPrefix("wait-file:"), step != "state" { loadID = editor?.loadID }
            }
            RepoMenus.debugLog("done")
        }
    }

    /// The editor's text view controller, once made.
    private var debugEditorController: EditorTextController? {
        editorTextDelegate as? EditorTextController
    }

    /// One `-HistqEditorRun` step; `loadID` is the load the last step left (`wait-refresh`).
    private func runEditorStep(_ step: String, since loadID: Int?) async {
        let parts = step.split(separator: ":", maxSplits: 1, omittingEmptySubsequences: false).map(String.init)
        let value = parts.count > 1 ? parts[1] : ""
        switch parts[0] {
        case "append":
            let text = value.replacingOccurrences(of: "\\n", with: "\n")
            let typed = await debugWait(until: { self.debugEditorController?.debugAppend(text) == true })
            RepoMenus.debugLog(typed ? "append \(value)" : "append timeout")
        case "save":
            guard let task = saveEditor() else { return RepoMenus.debugLog("blocked") }
            await RepoMenus.debugLog(Self.debugName(task.value))
        case "keepmine":
            guard editor?.diskChange != nil else { return RepoMenus.debugLog("skipped") }
            guard let task = keepMine() else { return RepoMenus.debugLog("blocked") }
            await RepoMenus.debugLog(Self.debugName(task.value))
        case "leave":
            selectWIPFile(value)
            RepoMenus.debugLog(conflictLeave != nil ? "prompt" : "no-prompt")
        case "answer":
            switch value {
            case "save":
                leaveConflictSaving()
                // Its save, then its way out, end in one turn.
                _ = await debugWait(until: { self.editor?.saving != true })
            case "discard": leaveConflictDiscarding()
            case "cancel": cancelConflictLeave()
            default: return RepoMenus.debugLog("unknown \(step)")
            }
            RepoMenus.debugLog("answer \(value): open=\(openFile?.path ?? "graph") prompt=\(conflictLeave != nil) "
                + debugEditorState)
        case "wait-file":
            RepoMenus.debugLog("waiting \(value)")
            let marker = StatePaths.root.appending(path: value, directoryHint: .notDirectory)
            let seen = await debugWait(until: { FileManager.default.fileExists(atPath: marker.path) })
            RepoMenus.debugLog(seen ? "go \(value)" : "timeout")
        case "reload":
            let before = editor?.loadID
            reloadEditor()
            let loaded = await debugWait(until: {
                self.editor?.loadID != before && self.debugEditorController?.debugShowsCurrentLoad == true
            })
            RepoMenus.debugLog(loaded ? "reloaded" : "timeout")
        case "wait-refresh":
            await debugWaitRefresh(since: loadID)
        case "state":
            try? await Task.sleep(for: .milliseconds(500))
            RepoMenus.debugLog(debugEditorState)
        default:
            RepoMenus.debugLog("unknown \(step)")
        }
    }

    /// `wait-refresh`: a status refresh started here, its publish, then the editor's disk check it started (a newer
    /// one, when a watcher refresh replaced it), 10 s at most in all; never the watcher's own timing.
    private func debugWaitRefresh(since loadID: Int?) async {
        let deadline = ContinuousClock.now + .seconds(10)
        let reads = statusReads
        refresh(scope: [.status])
        guard await debugWait(until: deadline, { self.statusReads != reads }) else {
            return RepoMenus.debugLog("timeout")
        }
        // The disk check starts in the publish's turn; a newer refresh may replace it meanwhile.
        while let check = editorDiskTask {
            let ended = DebugFlag()
            Task { @MainActor in
                await check.value
                ended.isSet = true
            }
            guard await debugWait(until: deadline, { ended.isSet }) else { return RepoMenus.debugLog("timeout") }
            if editorDiskTask == check { break }
        }
        guard let editor else { return RepoMenus.debugLog("editor closed") }
        switch editor.diskChange {
        case .deleted?: RepoMenus.debugLog("diskChange deleted")
        case .modified?: RepoMenus.debugLog("diskChange modified")
        case nil: RepoMenus.debugLog(editor.loadID != loadID ? "reloaded" : "unchanged")
        }
    }

    /// `state`'s line.
    private var debugEditorState: String {
        guard let editor else { return "editor closed" }
        return "editor open \(editor.path) shows=\(editor.showsEditor ? "edit" : "diff") "
            + "dirty=\(editor.isDirty ? "yes" : "no")"
    }

    private static func debugName(_ outcome: EditorSaveOutcome) -> String {
        switch outcome {
        case .saved: "saved"
        case .blocked: "blocked"
        case .failed: "failed"
        }
    }

    /// Polls `condition` every 20 ms until it holds (true) or 10 s pass (false).
    private func debugWait(until condition: () -> Bool) async -> Bool {
        await debugWait(until: .now + .seconds(10), condition)
    }

    private func debugWait(until deadline: ContinuousClock.Instant, _ condition: () -> Bool) async -> Bool {
        while !condition() {
            guard ContinuousClock.now < deadline else { return false }
            try? await Task.sleep(for: .milliseconds(20))
        }
        return true
    }
}

/// A flag set by one main-actor task and polled by another (`wait-refresh`'s disk check).
@MainActor
private final class DebugFlag {
    var isSet = false
}
#endif
