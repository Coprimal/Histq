// The AI actions' result, an in-window `ModalCard` (never a native sheet), opened by the AI buttons: Generate Message
// (commit box), Explain (commit details, WIP) and Suggest Resolution (conflict editor). A click opens the card in its
// frame with a skeleton; the diff is read and the prompt built off the main actor, then the answer streams in as a
// preview (`AIPrompt.preview`), under a resolution's short reason (plain text, never applied). Apply uses only
// `AIPrompt.answer(from:)`: a commit message fills the commit box, a resolution replaces the current conflict region's
// Output as a manual edit (never saved or staged). Copy copies the answer; Regenerate runs the same job again in a
// fresh card; Cancel stops the stream at once and closes the card. Errors show their `description`, never a key.
import AppKit
import HistqCore
import SwiftUI

/// What an AI button asks for.
enum AIJob: Equatable, Sendable {
    /// `summaryOnly`: Settings › AI › Summary only, taken at the click (Apply then keeps the description). `amend`:
    /// Amend was on, so the message describes the whole amended commit; `currentMessage` is the commit box's message
    /// at the click (the one being amended; sent only with `amend`).
    case commitMessage(summaryOnly: Bool, amend: Bool, currentMessage: String)
    /// `message`: the commit's subject and body.
    case explainCommit(hash: String, message: String)
    case explainWorkingChanges
    /// A reword row's Improve (interactive rebase): `message` is the row's message at the click; Apply (the row's
    /// `onApply`) replaces it with the whole answer.
    case improveMessage(hash: String, message: String)
    /// The squash sheet's Generate: `messages` are the squashed commits' full messages, oldest first; Apply (the
    /// sheet's `onApply`) fills its summary and description.
    case squashMessage(messages: [String])
    case resolution(AIResolutionTarget)
    /// The Create Pull Request form's Generate: `base` and `head` are the remote-tracking refs GitHub compares (full
    /// refs); the template is read at `templateRef` (the default branch's, else the base), where `kind`'s host looks
    /// for it. Apply (the form's `onApply`) fills the title and the description.
    case pullRequest(base: String, head: String, templateRef: String, kind: HostingKind)

    var title: String {
        switch self {
        case .commitMessage: "Commit message"
        case .explainCommit(let hash, _): "Explain commit \(hash.prefix(7))"
        case .explainWorkingChanges: "Explain the uncommitted changes"
        case .improveMessage: "Improve message"
        case .squashMessage(let messages): "Message of \(messages.count) squashed commits"
        case .resolution(let target): "Resolve conflict \(target.conflict + 1) of \(target.path)"
        case .pullRequest(_, _, _, let kind): "\(kind.pullRequestNoun) description"
        }
    }

    /// The timing log's name of the job.
    var logName: String {
        switch self {
        case .commitMessage: "commit-message"
        case .explainCommit: "explain-commit"
        case .explainWorkingChanges: "explain-wip"
        case .improveMessage: "improve-message"
        case .squashMessage: "squash-message"
        case .resolution: "resolution"
        case .pullRequest: "pull-request"
        }
    }

    /// Whether the answer can be applied (an explanation is only shown and copied).
    var canApply: Bool {
        switch self {
        case .commitMessage, .resolution, .improveMessage, .squashMessage, .pullRequest: true
        case .explainCommit, .explainWorkingChanges: false
        }
    }
}

/// One conflict region as it was when Suggest Resolution was clicked: Apply replaces that region only, and only while
/// the editor still shows the same load of the same file.
struct AIResolutionTarget: Equatable, Sendable {
    let path: String
    let loadID: Int
    /// "conflict k of N" (0-based).
    let conflict: Int
    /// The index of the conflict's region in `ThreeWayMerge.regions`.
    let region: Int
    /// nil for an add/add conflict, which has no base.
    let base: String?
    let a: String
    let b: String
    /// The file's line break ("\r\n" or "\n", `ThreeWayMerge.lineBreak`): the answer is converted to it.
    let lineBreak: String
    /// The region ends with a line break (`ThreeWayMerge.needsFinalBreak(region:)`); `AIPrompts.resolutionText` adds
    /// or drops the answer's final one to match.
    let needsFinalBreak: Bool
    /// The operation in progress at the click and its pane labels (`RepoState`): what the prompt's intent is read from.
    let operation: RepoState.Operation
    let labels: ConflictLabels
}

/// Why a job could not start; shown in the card.
enum AIJobError: Error, CustomStringConvertible {
    case nothingStaged
    case noChanges
    case allIgnored
    case fileIgnored
    case aiIgnoreUnreadable
    case noCommits

    var description: String {
        switch self {
        case .nothingStaged: "Nothing is staged. Stage the changes the message should describe."
        case .noChanges: "There are no changes to explain (new untracked files are not included)."
        case .allIgnored: "Every changed file is excluded by .aiignore; nothing was sent."
        case .fileIgnored: "This file is excluded by .aiignore; nothing was sent."
        case .aiIgnoreUnreadable:
            "The .aiignore file can't be read (symlink, not a file, or over 64 KB); nothing was sent."
        case .noCommits: "The head branch has no commits past the base."
        }
    }
}

/// A running or finished AI job: the prompt, the reply so far, and the outcome. The job runs in `task`, which the
/// card's Cancel, Escape, a tab or page change, closing the tab or window, a new job and the run's own deinit cancel
/// (that drops the stream and stops the request).
@Observable
@MainActor
final class AIRun: Identifiable {
    enum Phase: Equatable {
        case preparing
        case streaming
        /// The answer block, ready to apply or copy.
        case finished(String)
        case failed(String)
    }

    let id = UUID()
    let job: AIJob
    let provider: AIProvider
    let model: String
    /// A form's AI button: Apply hands it the answer (then closes the card) instead of the job's own apply.
    let onApply: (@MainActor (String) -> Void)?
    private(set) var phase = Phase.preparing
    /// What the card shows of the reply so far (the answer block only).
    private(set) var preview = ""
    /// A resolution's short reason (`AIPrompt.reason(from:)`), updated with the preview: shown as plain text, never
    /// applied.
    private(set) var reason: String?
    private(set) var reply = ""
    /// Not observed, so `deinit` (nonisolated) can cancel it.
    @ObservationIgnored private var task: Task<Void, Never>?

    init(job: AIJob, provider: AIProvider, model: String, onApply: (@MainActor (String) -> Void)? = nil) {
        self.job = job
        self.provider = provider
        self.model = model
        self.onApply = onApply
    }

    deinit {
        // The task holds only a weak reference: without this, a run dropped with its tab or window would still read
        // the key and send the content.
        task?.cancel()
    }

    var answer: String? {
        if case .finished(let answer) = phase { return answer }
        return nil
    }

    var isRunning: Bool { phase == .preparing || phase == .streaming }

    /// Reads the job's content and streams the answer. `prompt` runs off the main actor (git reads, the diff budget).
    /// `onFinish` runs once when the job ends, however it ends (answer, failure, cancel, the run dropped): what Suggest
    /// All awaits before it asks the next region. It is held by the task, never by the run.
    func start(prompt: @escaping @Sendable () async throws -> AIPrompt, onFinish: (@MainActor () -> Void)? = nil) {
        task?.cancel()
        let provider = provider
        let model = model
        task = Task { [weak self] in
            defer { onFinish?() }
            do {
                let prompt = try await prompt()
                try Task.checkCancellation()
                let client = try await AISetup.shared.makeClient(for: provider)
                // The last point before anything leaves the Mac: a run cancelled or dropped meanwhile sends nothing.
                guard self != nil, !Task.isCancelled else { return }
                self?.phase = .streaming
                var shown = ContinuousClock.now
                do {
                    for try await piece in client.stream(prompt.request(model: model)) {
                        guard let self else { return }
                        reply += piece
                        // `preview(of:)` reads the whole reply, so one call per piece is quadratic: at most ~20 a
                        // second, but at once while nothing shows (the first words' timing and the cancel seam).
                        guard preview.isEmpty || ContinuousClock.now - shown >= .milliseconds(50) else { continue }
                        preview = prompt.preview(of: reply)
                        reason = prompt.reason(from: reply)
                        shown = .now
                    }
                } catch {
                    // A failed stream shows what came with the error: the throttle may have held back the end.
                    if let self {
                        preview = prompt.preview(of: reply)
                        reason = prompt.reason(from: reply)
                    }
                    throw error
                }
                try Task.checkCancellation()
                guard let self else { return }
                preview = prompt.preview(of: reply)
                reason = prompt.reason(from: reply)
                do {
                    phase = .finished(try prompt.answer(from: reply))
                } catch {
                    phase = .failed(String(describing: error))
                }
            } catch {
                guard !(error is CancellationError), !Task.isCancelled else { return }
                self?.phase = .failed(String(describing: error))
            }
        }
    }

    func cancel() {
        task?.cancel()
        task = nil
    }
}

/// The card of an `AIRun` (`ModalHost`).
struct AIResultSheet: View {
    let session: RepoSession
    let run: AIRun
    let onClose: () -> Void
    @State private var applyError: String?
    @State private var copied = false
    /// The first words (or the outcome) showed: logged once.
    @State private var contentLogged = false
    #if DEBUG
    @Environment(WindowModel.self) private var windowModel
    #endif

    private var detail: String { "ai \(run.job.logName)" }

    var body: some View {
        ModalCard(title: run.job.title, subtitle: "\(run.provider.displayName) · \(run.model)", systemImage: "sparkles",
                  width: 560, takesFocus: true) {
            // Inset like the footer's buttons: 16 pt from the modal's edges.
            previewBox
                .padding(.horizontal, ModalFooterMetrics.trailingPadding)
        } actions: {
            Button(run.isRunning ? "Cancel" : "Close", action: onClose)
                .buttonStyle(RowTextButtonStyle(formRow: true))
                .keyboardShortcut(.cancelAction)
                .help(run.isRunning ? "Stop the answer and close" : "Close")
            Button(copied ? "Copied" : "Copy", action: copy)
                .buttonStyle(RowTextButtonStyle(formRow: true))
                .disabled(run.answer == nil)
            if !run.isRunning {
                Button("Regenerate", action: regenerate)
                    .buttonStyle(RowTextButtonStyle(formRow: true))
                    .help("Ask again for a new answer")
            }
            if run.job.canApply {
                Button("Apply", action: apply)
                    .buttonStyle(RowTextButtonStyle(formRow: true, prominent: true))
                    .keyboardShortcut(.defaultAction)
                    .disabled(run.answer == nil)
                    .help(applyHelp)
            }
        }
        .onAppear {
            UITiming.placeholder(detail)
            #if DEBUG
            debugClose()
            #endif
        }
        .onChange(of: run.preview.isEmpty) { _, empty in
            if !empty { logContent() }
        }
        .onChange(of: run.phase) { _, phase in
            if !run.isRunning { logContent() }
            #if DEBUG
            debugFinished(phase)
            #endif
        }
        #if DEBUG
        .onChange(of: run.preview.count) { _, count in debugCancel(count) }
        #endif
    }

    private var applyHelp: String {
        switch run.job {
        case .commitMessage(let summaryOnly, _, _):
            summaryOnly ? "Fill the commit box's summary" : "Fill the commit box's summary and description"
        case .resolution: "Replace this conflict's Output (not saved until you click Save)"
        case .improveMessage: "Replace the row's new message"
        case .squashMessage: "Fill the squash's summary and description"
        case .pullRequest(_, _, _, let kind): "Fill the \(kind.pullRequestNoun.lowercased())'s title and description"
        default: ""
        }
    }

    private func logContent() {
        guard !contentLogged else { return }
        contentLogged = true
        UITiming.content(detail)
    }

    // MARK: Parts

    @ViewBuilder
    private var previewBox: some View {
        let text = run.answer ?? run.preview
        Group {
            if text.isEmpty && run.reason == nil && error == nil {
                VStack(alignment: .leading, spacing: 10) {
                    SkeletonLine(fraction: 0.7, height: 12)
                    SkeletonLine(fraction: 0.9, height: 12)
                    SkeletonLine(fraction: 0.55, height: 12)
                    SkeletonLine(fraction: 0.8, height: 12)
                    Spacer(minLength: 0)
                }
                .padding(12)
                .overlay {
                    if run.isRunning { DelayedSpinner(detail: detail) }
                }
                .accessibilityElement(children: .ignore)
                .accessibilityLabel("Waiting for the answer")
            } else {
                ScrollView {
                    // An error shows under what came of the answer, in the same box.
                    VStack(alignment: .leading, spacing: 8) {
                        // Plain text only: the reason is steered by repo content and is never applied.
                        if let reason = run.reason {
                            Text(verbatim: reason)
                                .foregroundStyle(.secondary)
                                .textSelection(.enabled)
                        }
                        if !text.isEmpty { previewText(text) }
                        ErrorText(message: error)
                    }
                    .frame(maxWidth: .infinity, minHeight: AIResultMetrics.previewHeight - 16, alignment: .topLeading)
                    .padding(.horizontal, 11)
                    .padding(.vertical, 8)
                }
                .defaultScrollAnchor(.bottom)
            }
        }
        .frame(height: AIResultMetrics.previewHeight)
        .frame(maxWidth: .infinity, alignment: .topLeading)
        .background(RoundedRectangle(cornerRadius: SettingsInputMetrics.cornerRadius, style: .continuous)
            .fill(Palette.inputSurface))
    }

    @ViewBuilder
    private func previewText(_ text: String) -> some View {
        switch run.job {
        case .resolution:
            Text(verbatim: text)
                .font(.body.monospaced())
                .textSelection(.enabled)
        case .explainCommit, .explainWorkingChanges:
            Text(Self.markdown(text))
                .textSelection(.enabled)
        case .commitMessage, .improveMessage, .squashMessage, .pullRequest:
            Text(verbatim: text)
                .textSelection(.enabled)
        }
    }

    /// The job's failure, or Apply's.
    private var error: String? {
        if case .failed(let message) = run.phase { return message }
        return applyError
    }

    /// Inline markdown (bold, italic, code) with the line breaks kept; links are shown as plain text, never opened.
    private static func markdown(_ text: String) -> AttributedString {
        let options = AttributedString.MarkdownParsingOptions(interpretedSyntax: .inlineOnlyPreservingWhitespace)
        var styled = (try? AttributedString(markdown: text, options: options)) ?? AttributedString(text)
        // The answer is steered by untrusted repo content (a commit message or diff can ask for a link), so no run
        // stays clickable: a link's text is kept as plain text and its target is dropped.
        for run in styled.runs where run.link != nil {
            styled[run.range].link = nil
        }
        return styled
    }

    // MARK: Actions

    private func copy() {
        guard let answer = run.answer else { return }
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(answer, forType: .string)
        copied = true
    }

    /// The same job again in a new `AIRun`, so the card starts fresh.
    private func regenerate() {
        session.startAI(run.job, onApply: run.onApply)
    }

    private func apply() {
        guard let answer = run.answer else { return }
        if let onApply = run.onApply {
            onApply(answer)
            onClose()
            return
        }
        switch run.job {
        case .commitMessage(let summaryOnly, _, _):
            session.applyAICommitMessage(answer, summaryOnly: summaryOnly)
            onClose()
        case .resolution(let target):
            if let error = session.applyAIResolutions([(target, answer)]) {
                applyError = error
            } else {
                onClose()
            }
        case .explainCommit, .explainWorkingChanges, .improveMessage, .squashMessage, .pullRequest:
            break
        }
    }

    #if DEBUG
    /// DEBUG `-HistqAI <hook>,apply`: applies the finished answer as the Apply button does; logs the outcome.
    private func debugFinished(_ phase: AIRun.Phase) {
        switch phase {
        case .finished(let answer):
            let firstLine = answer.split(separator: "\n").first.map(String.init) ?? ""
            AIStub.log("finished \(run.job.logName) chars \(answer.count) first-line \(AIStub.quoted(firstLine))"
                + (run.reason.map { " reason \(AIStub.quoted($0))" } ?? ""))
            if AIStub.takeRegenerate() {
                regenerate()
                return
            }
            guard AIStub.seamOptions.contains("apply") else { return }
            let before = session.conflict.value?.merge
            apply()
            AIStub.log("apply \(run.job.logName) error \(applyError ?? "none") card-open \(session.aiRun != nil)")
            AIStub.log("form-open \(run.job.logName) \(session.rebaseRequest != nil || session.pullRequestForm != nil)")
            switch run.job {
            case .commitMessage:
                let draft = session.commitDraft
                AIStub.log("commit-box summary \(AIStub.quoted(draft.summary)) description "
                    + AIStub.quoted(draft.description))
            case .resolution(let target):
                guard let before, let after = session.conflict.value?.merge else { return }
                let manual = after.regions.indices.filter { after.regions[$0].isManual }
                let changed = after.regions.indices.filter {
                    after.regions[$0].isManual != before.regions[$0].isManual
                        || after.regions[$0].isUnresolved != before.regions[$0].isUnresolved
                }
                let region = after.regions[target.region]
                AIStub.log("resolution conflict \(target.conflict) region \(target.region) manual-regions \(manual) "
                    + "changed-regions \(changed) unresolved \(before.unresolvedCount)->\(after.unresolvedCount) "
                    + "line-break \(AIStub.quoted(target.lineBreak)) output \(AIStub.quoted(after.outputLines[region.output].joined()))")
            case .explainCommit, .explainWorkingChanges, .improveMessage, .squashMessage, .pullRequest:
                break
            }
        case .failed(let message):
            AIStub.log("failed \(run.job.logName): \(message)")
        case .preparing, .streaming:
            break
        }
    }

    /// DEBUG `-HistqAI <hook>,close-tab|close-window`: closes the card's tab (another tab must stay open) or window
    /// while the job still reads its content, as ⌘W would; ai.log must then show no stub request.
    private func debugClose() {
        let options = AIStub.seamOptions
        let closesTab = options.contains("close-tab")
        guard closesTab || options.contains("close-window") else { return }
        AIStub.log("close-\(closesTab ? "tab" : "window") \(run.job.logName) phase "
            + (run.phase == .preparing ? "preparing" : String(describing: run.phase)))
        if closesTab {
            guard let id = windowModel.sessions.first(where: { $0.value === session })?.key else { return }
            _ = windowModel.closeTab(id: id)
        } else {
            windowModel.closeWindow()
        }
    }

    /// DEBUG `-HistqAI <hook>,cancel`: Cancel as soon as the first words show.
    private func debugCancel(_ count: Int) {
        guard count > 0, run.isRunning, AIStub.seamOptions.contains("cancel") else { return }
        AIStub.log("cancel \(run.job.logName) after reply chars \(run.reply.count)")
        onClose()
    }
    #endif
}

enum AIResultMetrics {
    /// Tall enough for a commit message or a short explanation without scrolling; fits the smallest window.
    static let previewHeight: CGFloat = 240
}

/// An AI button of a card: disabled, with a tooltip saying where to set one up, while the active provider is not set
/// up; `unavailable` disables it for a reason of its own (nothing staged). A click only opens the result card: nothing
/// is sent before it. Draws nothing while Settings › AI › Show AI features is off.
struct AIHookButton: View {
    let title: String
    var systemImage: String?
    var help: String
    var unavailable: String?
    /// DEBUG `-HistqAI <seam>`: the hook a QA launch clicks.
    var seam: String
    /// In a card header: a step smaller than `RowTextButtonStyle`'s callout.
    var small = false
    /// A narrow header's fallback: the symbol alone (`sparkles` without one), the title in the tooltip.
    var iconOnly = false
    let action: () -> Void
    @AppStorage(PrefKey.aiShowFeatures.rawValue, store: Preferences.defaults)
    private var showFeatures = true

    private var setup: AISetup { .shared }

    var body: some View {
        if showFeatures { button }
    }

    @ViewBuilder
    private var button: some View {
        let ready = setup.isReady
        let reason = ready ? unavailable : AISetup.setUpHint
        Button(action: action) {
            HStack(spacing: 4) {
                if iconOnly {
                    Image(systemName: systemImage ?? "sparkles")
                        .accessibilityHidden(true)
                } else {
                    if let systemImage {
                        Image(systemName: systemImage)
                            .accessibilityHidden(true)
                    }
                    Text(title)
                        .lineLimit(1)
                }
            }
            .font(small ? .subheadline.weight(.medium) : .callout.weight(.medium))
        }
        .buttonStyle(RowTextButtonStyle())
        .fixedSize()
        .disabled(reason != nil)
        .help(iconOnly ? "\(title): \(reason ?? help)" : reason ?? help)
        .accessibilityLabel(title)
        .onAppear { setup.loadKeysIfNeeded() }
        #if DEBUG
        .task(id: reason) {
            guard let reason else {
                if AIStub.takeSeam(seam) { action() }
                return
            }
            // The button's own reason only (never the set-up hint): why a QA launch's hook did not click.
            if ready { AIStub.logUnavailable(seam, reason: reason) }
        }
        #endif
    }
}
