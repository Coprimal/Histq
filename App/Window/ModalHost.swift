// The window's modals (task 9.6): the repo operation's forms, confirmations, host-key and rebase cards
// (`RepoSession`), and the window's own (`WindowModel.modal`: a view's confirmation, Generate Key). Drawn in the window
// like the command palette, not as sheets: a scrim over the content `MainView` blurs, then the card in the middle. It
// shows in the frame that sets its state. Escape cancels; the focus moves into the card and goes back to the view
// that had it once it closes. The AppKit toolbar stays live above the scrim: a tab or page change cancels the modal.
// Settings (task 9.7) is the bottom layer: the modals it opens (Generate Key, a profile's deletion) and a form a
// toolbar action opens meanwhile stack above it, with their own scrim, while its card is blurred and disabled.
// An AI card opened from the rebase or pull request form stacks above the form the same way, so the form keeps its
// input; Escape then closes only the AI card.
import AppKit
import SwiftUI

extension EnvironmentValues {
    /// The most height a modal's card may take in the window (`ModalHost`'s layer, less its margins); nil until laid
    /// out. A form taller than that scrolls its content and keeps its buttons in view.
    @Entry var modalAvailableHeight: CGFloat?
}

/// A modal of the window that is not a repo operation's.
enum WindowModal: Identifiable {
    case confirmation(ModalConfirmation)
    /// Settings › SSH › Generate Key… for a profile.
    case generateKey(profileID: UUID)
    /// A tab's menu › Set Alias… for the tab `tabID`.
    case tabAlias(tabID: UUID)
    /// A tab's menu › Set Emoji… for the tab `tabID`.
    case tabEmoji(tabID: UUID)
    /// A tab group's name › Rename Group… for the group `key` (`TabGroupNames`).
    case groupName(key: String)
    /// The palette's File History… (or Blame… when `blame`): a search of the tab `tabID`'s tracked files.
    case fileSearch(tabID: UUID, blame: Bool)

    var id: String {
        switch self {
        case .confirmation(let confirmation): "confirm \(confirmation.title)"
        case .generateKey(let id): "generate key \(id)"
        case .tabAlias(let id): "tab alias \(id)"
        case .tabEmoji(let id): "tab emoji \(id)"
        case .groupName(let key): "group name \(key)"
        case .fileSearch(let id, let blame): "file search \(id) \(blame)"
        }
    }
}

/// The modal on screen, its own view: only this view reads the modal state, so opening one never re-evaluates
/// `MainView`.
struct ModalHost: View {
    let model: WindowModel
    /// The modal layer's height, once laid out.
    @State private var layerHeight: CGFloat?
    /// The auto-stash confirmation's "Always do this", unticked for each new one.
    @State private var alwaysDo = false

    /// One modal at a time; a window modal first, then the shown tab's (only one of those is set in practice).
    private enum Shown {
        case window(WindowModal)
        case confirmation(RepoSession, OperationConfirmation)
        case hostKey(RepoSession, HostKeyCheck)
        case dialog(RepoSession, OperationDialog)
        case rebase(RepoSession, RebaseRequest)
        case worktree(RepoSession, WorktreeForm)
        case pullRequest(RepoSession, PullRequestForm)
        case patch(RepoSession, PatchPreviewRequest)
        case ai(RepoSession, AIRun)
        case aiBatch(RepoSession, AIBatch)
        case conflictSave(RepoSession)
        case conflictLeave(RepoSession, String)

        var id: String {
            switch self {
            case .window(let modal): modal.id
            case .confirmation(_, let confirmation): "confirm \(confirmation.id)"
            case .hostKey(_, let check): "host key \(check.id)"
            case .dialog(_, let dialog): "dialog \(dialog.id)"
            case .rebase(_, let request): "rebase \(request.id)"
            case .worktree(_, let form): "worktree \(form.id)"
            case .pullRequest(_, let form): "pull request \(form.id)"
            case .patch(_, let request): "patch \(request.id)"
            case .ai(_, let run): "ai \(run.id)"
            case .aiBatch(_, let batch): "ai batch \(batch.id)"
            case .conflictSave: "conflict save"
            case .conflictLeave(_, let name): "conflict leave \(name)"
            }
        }

        /// A click on the scrim cancels a confirmation, which has nothing to lose; a form keeps its input.
        var closesOnScrimTap: Bool {
            switch self {
            case .window(.confirmation), .window(.fileSearch), .confirmation, .conflictSave, .conflictLeave: true
            default: false
            }
        }
    }

    private var shown: Shown? {
        if let modal = model.modal { return .window(modal) }
        guard let session = model.actionSession else { return nil }
        if let confirmation = session.confirmation { return .confirmation(session, confirmation) }
        if let check = session.hostKeyCheck { return .hostKey(session, check) }
        if let dialog = session.dialog { return .dialog(session, dialog) }
        if let request = session.rebaseRequest { return .rebase(session, request) }
        if let form = session.worktreeForm { return .worktree(session, form) }
        if let form = session.pullRequestForm { return .pullRequest(session, form) }
        if let request = session.patchPreview { return .patch(session, request) }
        if let run = session.aiRun { return .ai(session, run) }
        if let batch = session.aiBatch { return .aiBatch(session, batch) }
        if let leave = session.conflictLeave { return .conflictLeave(session, leave.name) }
        if session.conflictSavePrompt { return .conflictSave(session) }
        return nil
    }

    var body: some View {
        let shown = self.shown
        // Always there (an empty stack draws nothing and takes no clicks), so a tab or page change that hides the
        // modal in the same update still reaches the `onChange`s below.
        ZStack {
            // Under the other modals, never replaced by them: its section, profile and scroll stay as they were.
            if model.isSettingsOpen {
                SettingsLayer(model: model, isCovered: shown != nil)
            }
            if let shown {
                let cover = aiCover(shown)
                let covered = cover != nil
                ZStack {
                    ModalScrim { if shown.closesOnScrimTap { cancel(shown) } }
                    card(shown)
                        .environment(\.modalAvailableHeight,
                                     layerHeight.map { max(0, $0 - 2 * ModalMetrics.margin) })
                        .padding(ModalMetrics.margin)
                        // Always there, never in an `if`: the form keeps its identity and input under the AI card.
                        // Disabled at once (the backdrop disables late), so Return can't reach the form's button.
                        .modifier(ModalBackdrop(isActive: covered))
                        .disabled(covered)
                    if let cover {
                        ZStack {
                            ModalScrim()
                            AIResultSheet(session: cover.session, run: cover.run) { cover.session.closeAI() }
                                .environment(\.modalAvailableHeight,
                                             layerHeight.map { max(0, $0 - 2 * ModalMetrics.margin) })
                                .padding(ModalMetrics.margin)
                        }
                        .id("ai \(cover.run.id)")
                        .modifier(RestoresFocus())
                    }
                }
                // The scrim fills the window under the toolbar: a tall form fits its card in that (`CreatePRView`).
                .onGeometryChange(for: CGFloat.self, of: \.size.height) { layerHeight = $0 }
                // A new view per modal: the focus to restore starts over.
                .id(shown.id)
                .modifier(RestoresFocus())
                .onExitCommand {
                    if let cover { cover.session.closeAI() } else { cancel(shown) }
                }
            }
        }
        // The toolbar stays live above the scrim: the modal acts on the tab and page it opened on, so a change of
        // either cancels it.
        .onChange(of: shown?.id) { alwaysDo = false }
        .onChange(of: model.selectedTabID) { old, _ in
            if let old, let session = model.sessions[old], session.hasModal { session.closeModals() }
            if model.modal != nil { model.closeModal() }
        }
        .onChange(of: model.navigation.page) {
            if let session = model.selectedSession, session.hasModal { session.closeModals() }
            if model.modal != nil { model.closeModal() }
        }
    }

    @ViewBuilder
    private func card(_ shown: Shown) -> some View {
        switch shown {
        case .window(.confirmation(let confirmation)):
            ConfirmationModal(title: confirmation.title, message: confirmation.message, button: confirmation.button,
                              isDestructive: confirmation.isDestructive) {
                model.closeModal()
                confirmation.perform()
            } onCancel: {
                model.closeModal()
            }
        case .window(.generateKey(let profileID)):
            GenerateKeyModal(profileID: profileID) { model.closeModal() }
        case .window(.tabAlias(let tabID)):
            TabAliasModal(model: model, tabID: tabID) { model.closeModal() }
        case .window(.tabEmoji(let tabID)):
            TabEmojiModal(model: model, tabID: tabID) { model.closeModal() }
        case .window(.groupName(let key)):
            GroupNameModal(key: key) { model.closeModal() }
        case .window(.fileSearch(let tabID, let blame)):
            if let session = model.sessions[tabID] {
                FileSearchModal(session: session, blame: blame) { model.closeModal() }
            }
        case .confirmation(let session, let confirmation):
            ConfirmationModal(title: confirmation.title, message: confirmation.message, button: confirmation.button,
                              isDestructive: confirmation.isDestructive, secondary: confirmation.secondary?.button,
                              always: confirmation.asksAlways ? $alwaysDo : nil) {
                accept(confirmation, session, write: confirmation.write, remember: "always")
            } onCancel: {
                session.confirmation = nil
            } onSecondary: {
                if case .pull(let mode, _)? = confirmation.secondary?.write {
                    // The rejected push's Pull: an operation of its own (its title, button and auto-stash question).
                    session.confirmation = nil
                    session.pull(mode)
                } else if let secondary = confirmation.secondary {
                    accept(confirmation, session, write: secondary.write, remember: "never")
                }
            }
        case .hostKey(let session, let check):
            HostKeySheet(session: session, check: check) { session.hostKeyCheck = nil }
        case .dialog(let session, let dialog):
            OperationDialogView(session: session, dialog: dialog) { session.dialog = nil }
        case .rebase(let session, let request):
            InteractiveRebaseView(session: session, request: request) { session.rebaseRequest = nil }
        case .worktree(let session, let form):
            AddWorktreeView(session: session, form: form) { session.worktreeForm = nil }
        case .pullRequest(let session, let form):
            CreatePRView(session: session, form: form) { session.pullRequestForm = nil }
        case .patch(let session, let request):
            ApplyPatchModal(session: session, request: request) { session.patchPreview = nil }
        case .ai(let session, let run):
            AIResultSheet(session: session, run: run) { session.closeAI() }
        case .aiBatch(let session, let batch):
            AIBatchSheet(session: session, batch: batch) { session.closeAIBatch() }
        case .conflictSave(let session):
            ConflictSaveModal(session: session)
        case .conflictLeave(let session, let name):
            ConflictLeaveModal(session: session, fileName: name)
        }
    }

    /// Runs a confirmation's `write`; with "Always do this" ticked, stores `remember` as `PrefKey.autoStash` first.
    private func accept(_ confirmation: OperationConfirmation, _ session: RepoSession, write: RepoSession.Write,
                        remember: String)
    {
        if confirmation.asksAlways, alwaysDo {
            Preferences.defaults.set(remember, forKey: PrefKey.autoStash.rawValue)
        }
        session.confirmation = nil
        session.run(write, title: confirmation.operation, key: confirmation.key)
    }

    /// The AI card over the rebase or pull request form (`shown` keeps the form, so its card is not re-created).
    private func aiCover(_ shown: Shown) -> (session: RepoSession, run: AIRun)? {
        switch shown {
        case .rebase(let session, _), .pullRequest(let session, _): session.aiRun.map { (session, $0) }
        default: nil
        }
    }

    private func cancel(_ shown: Shown) {
        switch shown {
        case .window: model.closeModal()
        case .confirmation(let session, _): session.confirmation = nil
        case .hostKey(let session, _): session.hostKeyCheck = nil
        case .dialog(let session, _): session.dialog = nil
        case .rebase(let session, _): session.rebaseRequest = nil
        case .worktree(let session, _): session.worktreeForm = nil
        case .pullRequest(let session, _): session.pullRequestForm = nil
        case .patch(let session, _): session.patchPreview = nil
        case .ai(let session, _): session.closeAI()
        case .aiBatch(let session, _): session.closeAIBatch()
        case .conflictSave(let session): session.cancelConflictSave()
        case .conflictLeave(let session, _): session.cancelConflictLeave()
        }
    }
}

/// A tab's menu › Set Alias…: the tab's name in one field, the folder's name as its placeholder. Return saves; an empty
/// field gives the tab its folder's name back.
private struct TabAliasModal: View {
    let model: WindowModel
    let tabID: UUID
    let onClose: () -> Void
    @State private var alias = ""
    @FocusState private var fieldFocused: Bool

    var body: some View {
        let tab = model.tabs.first { $0.id == tabID }
        ModalCard(title: "Set an alias for \(tab?.repoURL?.lastPathComponent ?? "this tab")",
                  subtitle: "The tab shows this name instead of the folder's. Leave it empty to show the folder's name.",
                  width: 420) {
            TextField("Alias", text: $alias, prompt: Text(tab?.repoURL?.lastPathComponent ?? "Alias"))
                .textFieldStyle(.modal)
                .labelsHidden()
                .autocorrectionDisabled()
                .focused($fieldFocused)
                .onSubmit(save)
                .padding(.horizontal, ModalFooterMetrics.trailingPadding)
        } actions: {
            Button("Cancel", action: onClose)
                .buttonStyle(RowTextButtonStyle(formRow: true))
                .keyboardShortcut(.cancelAction)
            Button("Save", action: save)
                .buttonStyle(RowTextButtonStyle(formRow: true, prominent: true))
                .keyboardShortcut(.defaultAction)
        }
        .onAppear {
            alias = tab?.alias ?? ""
            // The card is installed on this turn; the field takes the focus on the next one.
            DispatchQueue.main.async { fieldFocused = true }
        }
    }

    private func save() {
        model.setAlias(alias, for: tabID)
        onClose()
    }
}

/// A tab group's name › Rename Group…: the group's name in one field, the main worktree's folder as its placeholder.
/// Return saves; an empty field gives the group its folder's name back.
private struct GroupNameModal: View {
    let key: String
    let onClose: () -> Void
    @State private var name = ""
    @FocusState private var fieldFocused: Bool

    var body: some View {
        let folder = RepoGroupKey.name(of: key)
        ModalCard(title: "Rename the \(folder) group",
                  subtitle: "The group's name shows this instead of the folder's, in every window. Leave it empty to "
                      + "show the folder's name.",
                  width: 420) {
            TextField("Name", text: $name, prompt: Text(folder))
                .textFieldStyle(.modal)
                .labelsHidden()
                .autocorrectionDisabled()
                .focused($fieldFocused)
                .onSubmit(save)
                .padding(.horizontal, ModalFooterMetrics.trailingPadding)
        } actions: {
            Button("Cancel", action: onClose)
                .buttonStyle(RowTextButtonStyle(formRow: true))
                .keyboardShortcut(.cancelAction)
            Button("Save", action: save)
                .buttonStyle(RowTextButtonStyle(formRow: true, prominent: true))
                .keyboardShortcut(.defaultAction)
        }
        .onAppear {
            name = TabGroupNames.shared.custom(of: key) ?? ""
            // The card is installed on this turn; the field takes the focus on the next one.
            DispatchQueue.main.async { fieldFocused = true }
        }
    }

    private func save() {
        TabGroupNames.shared.set(name, for: key)
        onClose()
    }
}

/// A tab's menu › Set Emoji…: the tab's emoji in one field that keeps only the last emoji typed or picked
/// (`TabEmoji.normalized`), with Choose… for the Character Viewer. Return saves; an empty field removes the emoji, as
/// Remove does.
private struct TabEmojiModal: View {
    let model: WindowModel
    let tabID: UUID
    let onClose: () -> Void
    @State private var emoji = ""
    @FocusState private var fieldFocused: Bool

    var body: some View {
        let tab = model.tabs.first { $0.id == tabID }
        ModalCard(title: "Set an emoji for \(tab?.repoURL?.lastPathComponent ?? "this tab")",
                  subtitle: "The tab shows this emoji at its left, and a pinned tab shows only it. Leave it empty for none.",
                  width: 420) {
            HStack(spacing: 8) {
                TextField("Emoji", text: $emoji, prompt: Text("Emoji"))
                    .textFieldStyle(.modal)
                    .labelsHidden()
                    .autocorrectionDisabled()
                    .focused($fieldFocused)
                    .onSubmit(save)
                    .onChange(of: emoji) { _, new in
                        let kept = TabEmoji.normalized(new) ?? ""
                        if kept != new { emoji = kept }
                    }
                Button("Choose…", action: choose)
                    .buttonStyle(RowTextButtonStyle(formRow: true))
            }
            .padding(.horizontal, ModalFooterMetrics.trailingPadding)
        } actions: {
            if tab?.emoji != nil {
                Button("Remove", action: remove)
                    .buttonStyle(RowTextButtonStyle(formRow: true))
            }
            Button("Cancel", action: onClose)
                .buttonStyle(RowTextButtonStyle(formRow: true))
                .keyboardShortcut(.cancelAction)
            Button("Save", action: save)
                .buttonStyle(RowTextButtonStyle(formRow: true, prominent: true))
                .keyboardShortcut(.defaultAction)
        }
        .onAppear {
            emoji = tab?.emoji ?? ""
            // The card is installed on this turn; the field takes the focus on the next one.
            DispatchQueue.main.async { fieldFocused = true }
        }
    }

    /// Focuses the field, then opens the Character Viewer on the next turn, so its pick goes into the field.
    private func choose() {
        fieldFocused = true
        DispatchQueue.main.async { NSApp.orderFrontCharacterPalette(nil) }
    }

    private func remove() {
        model.setEmoji(nil, for: tabID)
        onClose()
    }

    private func save() {
        model.setEmoji(emoji.isEmpty ? nil : emoji, for: tabID)
        onClose()
    }
}

/// The Settings modal (task 9.7) over the window content: a click on its scrim, Escape and the card's close button
/// close it. As large as the window allows (`ModalMetrics.margin` around it), up to `SettingsModalMetrics.maxWidth`.
private struct SettingsLayer: View {
    let model: WindowModel
    /// Another modal shows above it.
    let isCovered: Bool

    var body: some View {
        ZStack {
            ModalScrim { model.closeSettings() }
            SettingsModal { model.closeSettings() }
                .padding(ModalMetrics.margin)
        }
        // The window's toasts while it is open (Settings › AI › Save's too), over the card, not under the scrim.
        .overlay(alignment: .bottomTrailing) { ToastHost(model: model, overSettings: true) }
        .modifier(RestoresFocus())
        .onExitCommand { model.closeSettings() }
        // Behind a modal it opened, like the window content behind any modal.
        .modifier(ModalBackdrop(isActive: isCovered))
    }
}

/// Remembers the view that had the focus when the modal opened (not a text field's editor) and gives it the focus
/// back once the modal closes, on the next turn (Escape releases the field editor on its own turn).
private struct RestoresFocus: ViewModifier {
    @State private var previous = WeakView()

    func body(content: Content) -> some View {
        content
            .onAppear {
                if let responder = NSApp.keyWindow?.firstResponder as? NSView,
                   !((responder as? NSTextView)?.isFieldEditor ?? false)
                {
                    previous.view = responder
                }
            }
            .onDisappear {
                guard let view = previous.view else { return }
                DispatchQueue.main.async {
                    guard let window = view.window, window.isKeyWindow else { return }
                    window.makeFirstResponder(view)
                }
            }
    }

    /// Weak, so a closed tab's view is not kept alive by the modal.
    private final class WeakView {
        weak var view: NSView?
    }
}
