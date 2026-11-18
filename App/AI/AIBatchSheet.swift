// Suggest All (conflict editor): one suggestion per unresolved conflict region of the open file, asked one region
// after another (one request per region). Each region's prompt is built by `RepoSession.aiPrompt(for:)`, so the intent,
// the conflict instructions and the `.aiignore` re-check apply to every request. Apply writes the chosen answers in one
// step (`RepoSession.applyAIResolutions`), which Undo AI takes back.
import HistqCore
import SwiftUI

/// Suggest All's regions and their runs. `task` asks them in turn; Cancel stops the whole batch and the regions that
/// finished stay usable. The task holds the batch and its session weakly, so a batch dropped with its tab or window is
/// cancelled by `deinit` (its runs go with it, and theirs cancel their requests).
@Observable
@MainActor
final class AIBatch: Identifiable {
    let id = UUID()
    let targets: [AIResolutionTarget]
    /// One run per target, same order.
    let runs: [AIRun]
    /// The regions (indices in `targets`) Apply writes: each one is on as soon as it finishes.
    var use: Set<Int> = []
    /// Regions are still being asked; false once the last one ended, or after Cancel.
    private(set) var isRunning = false
    /// How many regions' runs started (the others wait or, after Cancel, were never asked).
    private(set) var started = 0
    /// Not observed, so `deinit` (nonisolated) can cancel it.
    @ObservationIgnored private var task: Task<Void, Never>?

    init(targets: [AIResolutionTarget], provider: AIProvider, model: String) {
        self.targets = targets
        runs = targets.map { AIRun(job: .resolution($0), provider: provider, model: model) }
    }

    deinit {
        task?.cancel()
    }

    /// The finished answers of the regions in `use`, in region order: what Apply writes.
    var chosen: [(AIResolutionTarget, String)] {
        targets.indices.compactMap { index in
            guard use.contains(index), let answer = runs[index].answer else { return nil }
            return (targets[index], answer)
        }
    }

    /// Asks the regions one after another: the next starts once the previous run ended (`AIRun.start`'s `onFinish`).
    /// Neither the batch nor `session` is held across a request.
    func start(session: RepoSession) {
        task?.cancel()
        isRunning = true
        task = Task { [weak self, weak session] in
            var index = 0
            while !Task.isCancelled {
                let asked = await withCheckedContinuation { (continuation: CheckedContinuation<Bool, Never>) in
                    guard let self, let session, index < self.runs.count else {
                        return continuation.resume(returning: false)
                    }
                    self.started = index + 1
                    self.runs[index].start(prompt: session.aiPrompt(for: .resolution(self.targets[index]))) {
                        continuation.resume(returning: true)
                    }
                }
                guard asked else { break }
                if self?.runs[index].answer != nil { self?.use.insert(index) }
                index += 1
            }
            self?.isRunning = false
        }
    }

    /// Cancel: stops the batch and the region being asked; the finished regions keep their answers.
    func cancel() {
        task?.cancel()
        task = nil
        for run in runs { run.cancel() }
        isRunning = false
    }
}

/// Suggest All's card (`ModalHost`): one row per region, each waiting, writing, finished (its reason and answer
/// preview, with a Use switch) or failed. Cancel stops the batch and keeps the card; Apply writes the chosen answers.
struct AIBatchSheet: View {
    let session: RepoSession
    let batch: AIBatch
    let onClose: () -> Void
    @State private var applyError: String?
    /// The first words (or the outcome) showed: logged once.
    @State private var contentLogged = false
    #if DEBUG
    @Environment(WindowModel.self) private var windowModel
    #endif

    private static let detail = "ai resolve-all"

    var body: some View {
        let count = batch.chosen.count
        let path = batch.targets.first?.path ?? ""
        let regions = batch.targets.count == 1 ? "1 conflict" : "\(batch.targets.count) conflicts"
        ModalCard(title: "Resolve \(regions) of \(path)",
                  subtitle: batch.runs.first.map { "\($0.provider.displayName) · \($0.model)" },
                  systemImage: "sparkles", width: 560, takesFocus: true) {
            VStack(alignment: .leading, spacing: 4) {
                ScrollView {
                    VStack(alignment: .leading, spacing: 0) {
                        ForEach(batch.targets.indices, id: \.self) { index in
                            if index > 0 { Divider() }
                            AIBatchRow(batch: batch, index: index)
                        }
                    }
                }
                .frame(height: AIResultMetrics.previewHeight + 80)
                .frame(maxWidth: .infinity, alignment: .topLeading)
                .background(RoundedRectangle(cornerRadius: SettingsInputMetrics.cornerRadius, style: .continuous)
                    .fill(Palette.inputSurface))
                ErrorText(message: applyError)
            }
            .padding(.horizontal, ModalFooterMetrics.trailingPadding)
        } actions: {
            if batch.isRunning {
                Button("Cancel") { batch.cancel() }
                    .buttonStyle(RowTextButtonStyle(formRow: true))
                    .keyboardShortcut(.cancelAction)
                    .help("Stop asking; the finished suggestions stay")
            } else {
                Button("Close", action: onClose)
                    .buttonStyle(RowTextButtonStyle(formRow: true))
                    .keyboardShortcut(.cancelAction)
            }
            Button("Apply \(count)", action: apply)
                .buttonStyle(RowTextButtonStyle(formRow: true, prominent: true))
                .keyboardShortcut(.defaultAction)
                .disabled(count == 0)
                .help("Replace the chosen conflicts' Output (not saved until you click Save)")
        }
        .onAppear {
            UITiming.placeholder(Self.detail)
            #if DEBUG
            debugClose()
            #endif
        }
        .onChange(of: batch.runs.first?.preview.isEmpty) { _, empty in
            if empty == false { logContent() }
        }
        .onChange(of: batch.isRunning) { _, running in
            guard !running else { return }
            logContent()
            #if DEBUG
            debugFinished()
            #endif
        }
    }

    private func logContent() {
        guard !contentLogged else { return }
        contentLogged = true
        UITiming.content(Self.detail)
    }

    private func apply() {
        if let error = session.applyAIResolutions(batch.chosen) {
            applyError = error
        } else {
            onClose()
        }
    }

    #if DEBUG
    /// DEBUG `-HistqAI resolve-all[,apply][,undo]`: logs the outcome once the batch ended; `apply` clicks Apply N,
    /// `undo` then does what the editor's Undo AI does.
    private func debugFinished() {
        let ok = batch.runs.filter { $0.answer != nil }.count
        let failed = batch.runs.filter { if case .failed = $0.phase { true } else { false } }.count
        AIStub.log("batch finished ok=\(ok) failed=\(failed)")
        let options = AIStub.seamOptions
        guard AIStub.seamHook == "resolve-all", options.contains("apply") else { return }
        let regions = batch.chosen.map { $0.0.region }
        apply()
        AIStub.log("apply-batch regions \(regions) error \(applyError ?? "none")")
        guard options.contains("undo") else { return }
        guard session.canUndoAIResolutions else { return AIStub.log("undo unavailable") }
        let before = session.conflict.value?.merge?.unresolvedCount ?? -1
        session.undoAIResolutions()
        let after = session.conflict.value?.merge?.unresolvedCount ?? -1
        AIStub.log("unresolved \(before)->\(after)")
    }

    /// DEBUG `-HistqAI resolve-all,close-tab|close-window`: closes the card's tab (another tab must stay open) or
    /// window while the batch runs, as ⌘W would; ai.log must then show no more stub requests.
    private func debugClose() {
        let options = AIStub.seamOptions
        let closesTab = options.contains("close-tab")
        guard AIStub.seamHook == "resolve-all", closesTab || options.contains("close-window") else { return }
        AIStub.log("close-\(closesTab ? "tab" : "window") resolve-all started \(batch.started) of \(batch.runs.count)")
        if closesTab {
            guard let id = windowModel.sessions.first(where: { $0.value === session })?.key else { return }
            _ = windowModel.closeTab(id: id)
        } else {
            windowModel.closeWindow()
        }
    }
    #endif
}

/// One region of Suggest All's card: its own view, so a streaming preview redraws only its row.
private struct AIBatchRow: View {
    let batch: AIBatch
    let index: Int

    var body: some View {
        let run = batch.runs[index]
        let text = run.answer ?? run.preview
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 8) {
                Text("Conflict \(batch.targets[index].conflict + 1)")
                    .font(.body.weight(.semibold))
                Spacer(minLength: 8)
                status(run)
            }
            // Plain text only: the reason and the answer are steered by repo content.
            if let reason = run.reason {
                Text(verbatim: reason)
                    .foregroundStyle(.secondary)
                    .textSelection(.enabled)
            }
            if !text.isEmpty {
                Text(verbatim: text)
                    .font(.body.monospaced())
                    .lineLimit(6)
                    .textSelection(.enabled)
            }
            if case .failed(let message) = run.phase {
                ErrorText(message: message)
            }
        }
        .padding(.horizontal, 11)
        .padding(.vertical, 8)
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    /// The Use switch once finished; else where the region stands. `AIRun.isRunning` can't tell: a run not asked yet
    /// or stopped by Cancel is still `.preparing` or `.streaming`.
    @ViewBuilder
    private func status(_ run: AIRun) -> some View {
        if run.answer != nil {
            Toggle("Use", isOn: Binding(
                get: { batch.use.contains(index) },
                set: { if $0 { batch.use.insert(index) } else { batch.use.remove(index) } }))
                .toggleStyle(.switch)
                .controlSize(.mini)
                .help("Apply this suggestion")
        } else if case .failed = run.phase {
            Text("Failed").foregroundStyle(.secondary)
        } else if batch.isRunning && index == batch.started - 1 {
            HStack(spacing: 6) {
                DelayedSpinner(detail: "ai resolve-all")
                Text("Writing…").foregroundStyle(.secondary)
            }
        } else if batch.isRunning {
            Text("Waiting").foregroundStyle(.secondary)
        } else {
            Text("Stopped").foregroundStyle(.secondary)
        }
    }
}
