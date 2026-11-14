// A commit or a stash in the detail panel, its parts in cards: the commit info (subject, body, author and
// committer with their avatars, date, sha with a copy button, parents that jump to their row, and the AI button
// Explain), then its files.
import AppKit
import Combine
import SwiftUI

struct CommitDetailPanel: View {
    let session: RepoSession
    let commit: CommitDetail
    /// The select this detail answers and its timing detail, passed in (not read from `session`): a view kept for its
    /// removal must not log the next select's lines.
    let token: Int
    let timingDetail: String

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
                                state: commit.files == nil ? "pending" : "loaded") {
                    files
                }
            }
        }
    }

    @ViewBuilder private var files: some View {
        if let files = commit.files {
            if files.isEmpty {
                Text("No file changes")
                    .foregroundStyle(.secondary)
                    .padding(.horizontal, 6)
                    .frame(height: FileListView<EmptyView>.rowHeight)
            } else {
                ScrollView {
                    FileListView(files: files, repoURL: session.url)
                        .fileMenu { [session, commit] file in
                            // A stash's untracked files are not in its commit: no checkout from a stash.
                            commit.isStash ? [] : RepoMenus.checkoutFile(file, commit: commit.hash, session: session)
                        }
                        .onSelectFile(selected: openPath) { [session, commit] file in
                            session.selectFile(FileTarget(source: .commit(commit.hash), file: file))
                        }
                }
                // Each commit's list starts at its top.
                .id(commit.hash)
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

    /// This commit's file whose diff panel2 shows, drawn as selected.
    private var openPath: String? {
        session.openFile?.source == .commit(commit.hash) ? session.openFile?.path : nil
    }
}

private enum CommitDetailMetrics {
    /// The info card's share of the panel's height at most; a longer message scrolls inside the card.
    static let infoFraction: CGFloat = 0.4
    /// The message's height at least (about two subject lines), even when the card's other rows alone pass
    /// `infoFraction` (a small window).
    static let messageMinHeight: CGFloat = 44
}

/// The commit detail's Files card, loaded or not: the count (a skeleton while nil), the paths/tree toggle, and a body
/// that takes the panel's height left under the info card. Logs its edges (`FilesLayoutLog`) as `state`.
private struct CommitFilesCard<Content: View>: View {
    let count: Int?
    let token: Int
    let detail: String
    /// `placeholder`, `pending` (a header from the log, files loading) or `loaded`.
    let state: String
    @ViewBuilder let content: () -> Content

    var body: some View {
        SectionCard("Files", systemImage: "doc.on.doc", count: count, countIsLoading: count == nil, contentPadding: 6) {
            // One stack: a frame on a list of views (skeleton rows) would apply to each row.
            VStack(alignment: .leading, spacing: 0) {
                content()
            }
            .frame(maxHeight: .infinity, alignment: .top)
        } accessory: {
            FileListModeToggle()
        }
        .modifier(FilesLayoutLog(token: token, detail: detail, state: state))
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
                    line(.title3.weight(.semibold), fraction: 0.75, height: 16)
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
            CommitFilesCard(count: nil, token: token, detail: detail, state: "placeholder") {
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

/// Several graph rows selected.
struct MultipleSelectionCard: View {
    let count: Int

    var body: some View {
        SectionCard("Selection", systemImage: "square.stack.3d.up") {
            Text("\(count) commits selected")
                .font(.body.weight(.medium))
        }
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

    var body: some View {
        SectionCard(commit.isStash ? "Stash" : "Commit",
                    systemImage: commit.isStash ? "archivebox" : "smallcircle.filled.circle") {
            // The card's body, under its header and above its bottom padding: the message gets what the other rows
            // leave of the card's `maxHeight`.
            CappedMessageLayout(
                maxHeight: maxHeight - SectionCardMetrics.headerHeight - SettingsMetrics.cardPadding,
                minMessageHeight: CommitDetailMetrics.messageMinHeight, spacing: 10
            ) {
                // As tall as the message up to its cap, then a scroll view of that height.
                ViewThatFits(in: .vertical) {
                    message
                    ScrollView {
                        message
                            .frame(maxWidth: .infinity, alignment: .leading)
                    }
                    // Each commit's message starts at its top.
                    .id(commit.hash)
                }
                VStack(alignment: .leading, spacing: 10) {
                    PersonRow(role: "Author", name: commit.authorName, email: commit.authorEmail,
                              date: format(commit.authorDate))
                    if commit.committerName != commit.authorName || commit.committerEmail != commit.authorEmail {
                        PersonRow(role: "Committer", name: commit.committerName, email: commit.committerEmail,
                                  date: format(commit.committerDate))
                    }
                    ShaRow(hash: commit.hash)
                    parentsRow
                }
            }
            .onChange(of: token, initial: true) { UITiming.contentInfo(timingDetail) }
        } accessory: {
            // AI (task 12.3): opens the result card; nothing is sent before the click.
            AIHookButton(title: "Explain", systemImage: "sparkles",
                         help: commit.isStash ? "Explain this stash with AI" : "Explain this commit with AI",
                         seam: "explain") {
                let message = commit.body.isEmpty ? commit.subject : commit.subject + "\n\n" + commit.body
                session.startAI(.explainCommit(hash: commit.hash, message: message))
            }
        }
    }

    private var message: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(commit.subject)
                .font(.title3.weight(.semibold))
                .fixedSize(horizontal: false, vertical: true)
            if !commit.body.isEmpty {
                Text(commit.body)
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
                    .foregroundStyle(.secondary)
                    .frame(width: InfoMetrics.labelWidth, alignment: .leading)
                ForEach(parents, id: \.self) { parent in
                    Button(String(parent.prefix(7))) {
                        session.selectGraph([.commit(parent)])
                    }
                    .buttonStyle(RowTextButtonStyle())
                    .font(.body.monospaced())
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
    static let avatar: CGFloat = 28
}

/// An avatar, the name, then the email and the date under it.
private struct PersonRow: View {
    let role: String
    let name: String
    let email: String
    let date: String

    var body: some View {
        HStack(spacing: 8) {
            AvatarImage(email: email, name: name, size: InfoMetrics.avatar)
            VStack(alignment: .leading, spacing: 2) {
                HStack(spacing: 6) {
                    Text(name)
                        .font(.body.weight(.medium))
                        .lineLimit(1)
                    Text(role.lowercased())
                        .font(.settingsCaption)
                        .foregroundStyle(.tertiary)
                }
                Text(email.isEmpty ? date : "\(email) · \(date)")
                    .font(.settingsCaption)
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
                .foregroundStyle(.secondary)
                .frame(width: InfoMetrics.labelWidth, alignment: .leading)
            Text(hash)
                .font(.body.monospaced())
                .lineLimit(1)
                .truncationMode(.middle)
                .textSelection(.enabled)
            Button {
                NSPasteboard.general.clearContents()
                NSPasteboard.general.setString(hash, forType: .string)
                copied = true
            } label: {
                Image(systemName: copied ? "checkmark" : "doc.on.doc")
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
