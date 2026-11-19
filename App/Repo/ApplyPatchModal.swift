// The Apply Patch preview (`ModalHost`): the patch's files with their added and removed line counts, whether it
// applies, and the buttons that apply it to the working tree or, for a mail series, as commits. It opens at once in
// its loading state (UI rule: the click reacts first) and fills in once `RepoSession.openPatchPreview` has read it.
// Everything shown from the patch (paths, git's reason) is untrusted text: plain `Text(verbatim:)`, never Markdown.
import HistqCore
import SwiftUI

/// The card of a `PatchPreviewRequest`.
struct ApplyPatchModal: View {
    let session: RepoSession
    let request: PatchPreviewRequest
    let onClose: () -> Void

    var body: some View {
        ModalCard(title: "Apply Patch", subtitle: request.source, systemImage: "doc.badge.plus", width: 480,
                  takesFocus: true) {
            ModalSection(spacing: 10) {
                if let error = request.error {
                    ErrorText(message: error)
                } else if let preview = request.preview {
                    loaded(preview)
                } else {
                    placeholder
                }
            }
        } actions: {
            Button("Cancel", action: onClose)
                .buttonStyle(RowTextButtonStyle(formRow: true))
                .keyboardShortcut(.cancelAction)
            if request.preview?.isMailbox == true {
                Button("Apply as Commits", action: applyCommits)
                    .buttonStyle(RowTextButtonStyle(formRow: true))
                    .disabled(commitsReason != nil)
                    .help(commitsReason ?? "Apply each patch as a commit on the current branch")
            }
            Button("Apply to Working Tree", action: applyToWorkingTree)
                .buttonStyle(RowTextButtonStyle(formRow: true, prominent: true))
                .keyboardShortcut(.defaultAction)
                .disabled(workingTreeReason != nil)
                .help(workingTreeReason ?? "Apply the changes to the working tree, without committing them")
        }
        .onChange(of: request.isLoading) { _, loading in
            if !loading { UITiming.content(detail) }
        }
    }

    private var detail: String { "apply patch" }

    // MARK: Parts

    /// The loading state: rows in the file rows' shape, the spinner only when the read is slow.
    private var placeholder: some View {
        PlaceholderCard(token: request.id, detail: detail) {
            VStack(alignment: .leading, spacing: 10) {
                SkeletonLine(width: 90, height: 11)
                VStack(spacing: 0) {
                    ForEach(0..<3, id: \.self) { index in
                        HStack(spacing: 12) {
                            SkeletonLine(fraction: [0.7, 0.5, 0.6][index], height: 12)
                            SkeletonLine(width: 56, height: 11)
                        }
                        .frame(height: ApplyPatchMetrics.rowHeight)
                    }
                }
                SkeletonLine(width: 120, height: 12)
            }
        }
    }

    @ViewBuilder
    private func loaded(_ preview: PatchPreview) -> some View {
        Text(summary(preview))
            .font(.settingsCaption)
            .foregroundStyle(.secondary)
        ScrollView {
            LazyVStack(alignment: .leading, spacing: 0) {
                ForEach(preview.files, id: \.path) { file in
                    FileRow(file: file)
                }
            }
        }
        .scrollBounceBehavior(.basedOnSize)
        // As tall as its rows, up to the cap: a long patch scrolls and the modal stays compact.
        .frame(height: min(CGFloat(preview.files.count) * ApplyPatchMetrics.rowHeight, ApplyPatchMetrics.listMaxHeight))
        verdict(preview.verdict)
    }

    /// "3 files", and "· 2 commits" for a mail series.
    private func summary(_ preview: PatchPreview) -> String {
        let files = preview.files.count == 1 ? "1 file" : "\(preview.files.count) files"
        guard preview.isMailbox else { return files }
        return files + " · " + (preview.mailCount == 1 ? "1 commit" : "\(preview.mailCount) commits")
    }

    @ViewBuilder
    private func verdict(_ verdict: PatchPreview.Verdict) -> some View {
        switch verdict {
        case .clean:
            Label("Applies cleanly", systemImage: "checkmark.circle.fill")
                .foregroundStyle(Color(nsColor: Palette.diffAddedSign))
        case .threeWay:
            Label("Needs a 3-way merge: the result is staged and may conflict", systemImage: "arrow.triangle.merge")
                .foregroundStyle(Color.accentColor)
        case .fails(let reason):
            VStack(alignment: .leading, spacing: 4) {
                Label("Does not apply", systemImage: "xmark.octagon.fill")
                    .foregroundStyle(Color(nsColor: Palette.graphLanes[6]))
                if !reason.isEmpty {
                    Text(verbatim: reason)
                        .font(.settingsCaption)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                        .textSelection(.enabled)
                }
            }
        }
    }

    // MARK: State

    private var isOperationInProgress: Bool { session.repoState?.isOperationInProgress == true }

    private var hasConflicts: Bool {
        !(session.status.value?.conflicted.isEmpty ?? true) || !(session.repoState?.conflictedPaths.isEmpty ?? true)
    }

    /// Why the patch cannot be applied now, by either button: nil when it can.
    private var sharedReason: String? {
        if isOperationInProgress { return UndoError.operationInProgress.message }
        if hasConflicts { return "Resolve the conflicted files first." }
        return nil
    }

    /// Why Apply to Working Tree is disabled; nil when it is enabled.
    private var workingTreeReason: String? {
        guard request.data != nil, let preview = request.preview else {
            return request.isLoading ? "Reading the patch…" : "This patch cannot be applied."
        }
        if case .fails = preview.verdict { return "This patch does not apply to the working tree." }
        return sharedReason
    }

    /// Why Apply as Commits is disabled; nil when it is enabled.
    private var commitsReason: String? {
        guard request.data != nil, request.preview?.isMailbox == true else { return "This patch is not a mail series." }
        if let reason = sharedReason { return reason }
        if !(session.status.value?.staged.isEmpty ?? true) { return "Commit or unstage the staged changes first." }
        return nil
    }

    // MARK: Actions

    private func applyToWorkingTree() {
        guard workingTreeReason == nil, let data = request.data else { return }
        onClose()
        session.run(.applyPatchToWorkingTree(data), title: "Apply Patch")
    }

    private func applyCommits() {
        guard commitsReason == nil, let data = request.data, let preview = request.preview else { return }
        onClose()
        session.run(.applyPatchCommits(data, count: preview.mailCount), title: "Apply Patch")
    }
}

/// One file of the preview: its path (middle-truncated), then its added and removed line counts, or "binary".
private struct FileRow: View {
    let file: PatchPreview.File

    var body: some View {
        HStack(spacing: 12) {
            Text(verbatim: file.path)
                .lineLimit(1)
                .truncationMode(.middle)
                .help(file.path)
                .frame(maxWidth: .infinity, alignment: .leading)
            if file.isBinary {
                Text("binary")
                    .font(.caption.weight(.medium))
                    .foregroundStyle(.secondary)
                    .padding(.horizontal, 6)
                    .padding(.vertical, 1)
                    .overlay(Capsule().strokeBorder(.secondary.opacity(0.6), lineWidth: 1))
            } else {
                HStack(spacing: 6) {
                    Text(verbatim: "+\(file.additions)")
                        .foregroundStyle(Color(nsColor: Palette.diffAddedSign))
                    Text(verbatim: "−\(file.deletions)")
                        .foregroundStyle(Color(nsColor: Palette.diffRemovedSign))
                }
                .font(.callout.monospacedDigit().weight(.medium))
                .accessibilityElement(children: .ignore)
                .accessibilityLabel("\(file.additions) added, \(file.deletions) removed")
            }
        }
        .frame(height: ApplyPatchMetrics.rowHeight)
    }
}

private enum ApplyPatchMetrics {
    static let rowHeight: CGFloat = 24
    /// About eight rows; more scroll.
    static let listMaxHeight: CGFloat = 192
}
