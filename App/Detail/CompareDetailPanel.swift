// A compare in the detail panel: a header card "A ↔ B" with a swap button, then the files that differ, in the
// commit detail's Files card. A click on a file opens its diff (read-only) in panel2. The same view with no files is
// the compare's placeholder, so the cards keep their place when the files arrive.
import SwiftUI

struct CompareDetailPanel: View {
    let session: RepoSession
    let base: String
    /// Nil for the working tree.
    let head: String?
    /// The files that differ; nil while they are read (skeleton rows).
    let files: [FileChange]?
    /// The select this detail answers and its timing detail (see `CommitDetailPanel`).
    let token: Int
    let timingDetail: String

    var body: some View {
        VStack(spacing: SectionCardMetrics.spacing) {
            SectionCard("Compare", systemImage: "plus.forwardslash.minus") {
                VStack(alignment: .leading, spacing: 4) {
                    Text(verbatim: "\(label(base)) ↔ \(head.map(label) ?? "Working Tree")")
                        .font(.body.weight(.medium))
                        .lineLimit(1)
                        .truncationMode(.middle)
                        .textSelection(.enabled)
                    if head == nil {
                        Text("Untracked files are not included.")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }
                .padding(.top, SectionCardMetrics.accessoryGap)
            } accessory: {
                Button {
                    if let head { session.selectCompare(base: head, head: base) }
                } label: {
                    Image(systemName: "arrow.left.arrow.right")
                        .foregroundStyle(.secondary)
                }
                .buttonStyle(RowIconButtonStyle())
                // The working tree can't be the base.
                .disabled(head == nil)
                .help(head == nil ? "The working tree can't be the base" : "Swap Base and Head")
                .accessibilityLabel("Swap base and head")
            }
            CommitFilesCard(count: files?.count, token: token, detail: timingDetail,
                            state: files == nil ? "placeholder" : "loaded", allFilesButton: false) { query in
                CompareFileList(session: session, base: base, head: head, files: files, query: query)
            }
        }
    }

    /// A full object id as its short sha, a branch's full ref as its name, any other ref name as it is.
    private func label(_ rev: String) -> String {
        if rev.count >= 40 && rev.allSatisfy(\.isHexDigit) { return String(rev.prefix(7)) }
        for prefix in ["refs/heads/", "refs/remotes/"] where rev.hasPrefix(prefix) {
            return String(rev.dropFirst(prefix.count))
        }
        return rev
    }
}

/// A compare's files (`base` against `head`, nil for the working tree) that `query` matches (all with an empty query),
/// as a Files card's body: a click opens a file's diff (read-only) in panel2. Skeleton rows while `files` is nil.
struct CompareFileList: View {
    let session: RepoSession
    let base: String
    let head: String?
    let files: [FileChange]?
    let query: String
    @Environment(\.textSize) private var textSize

    var body: some View {
        if let files {
            let shown = FileSearch.filter(files, query: query)
            if shown.isEmpty {
                Text(files.isEmpty ? "No differences" : "No matching files")
                    .font(textSize.body)
                    .foregroundStyle(.secondary)
                    .padding(.horizontal, 6)
                    .frame(height: FileListView<EmptyView>.rowHeight(textSize))
            } else {
                CardScrollView {
                    FileListView(files: shown, repoURL: session.url, card: .commit)
                        .fileMenu { [session, head] file in
                            // Untracked files are not in a compare; a deleted file has only its history.
                            file.kind == .untracked ? []
                                : RepoMenus.fileTools(path: file.path, rev: head, blame: file.kind != .deleted,
                                                      session: session)
                        }
                        .onSelectFile(selected: openPath) { [session, source] file in
                            session.selectFile(FileTarget(source: source, file: file))
                        }
                }
                // Each compare's list starts at its top.
                .id(source)
            }
        } else {
            SkeletonFileRows(fractions: [0.6, 0.45, 0.7, 0.5])
        }
    }

    private var source: FileTarget.Source {
        .compare(base: base, head: head)
    }

    /// This compare's file whose diff or blame panel2 shows, drawn as selected.
    private var openPath: String? {
        session.openFile?.source == source ? session.openFile?.path : session.blamePath(in: source)
    }
}
