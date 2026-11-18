// A file's history in panel 1, in place of the sidebar: one card with the commits that changed it, newest first. A
// click on a commit selects it (panel 3) and opens the file's diff at that commit in panel 2 (the newest opens when the
// history loads); a file clicked in panel 3 shows that file's history. Panel 2's controls card has "Follow renames" and
// close: close or Esc shows the graph and the sidebar again (RepoLayoutView).
// The history loads off the main actor (`RepoSession.selectTool`); until then the card holds skeleton rows.
import HistqCore
import SwiftUI

/// Panel 1 while a file's history shows: the commits (skeletons until loaded).
struct FileHistoryView: View {
    let session: RepoSession
    /// The file history (`.fileHistory` of `path`, `rev`, `follow`): a row's diff keeps it in panel 1.
    let tool: RepoTool
    @Environment(WindowModel.self) private var model

    private var path: String {
        if case .fileHistory(let path, _, _) = tool { path } else { "" }
    }

    var body: some View {
        Group {
            switch session.toolState {
            case .loaded(.history(let entries)):
                HistoryCard(session: session, tool: tool, path: path, entries: entries)
                    .onAppear { UITiming.content(session.toolDetail) }
            case .failed(let message):
                DiffNoticeCard(title: "File History", systemImage: "exclamationmark.triangle", message: message)
                    .onAppear { UITiming.content("\(session.toolDetail) failed") }
            default:
                PlaceholderCard(
                    token: session.toolToken, detail: session.toolDetail,
                    isCurrent: { [model, session, tool] in
                        model.selectedSession === session && session.historyTool == tool
                    }
                ) {
                    HistoryPlaceholder()
                }
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
    }
}

/// The commits of the history, one row each, in a card that fills panel 1 and scrolls.
private struct HistoryCard: View {
    let session: RepoSession
    let tool: RepoTool
    let path: String
    let entries: [FileHistoryEntry]
    @AppStorage(PrefKey.dateFormat.rawValue, store: Preferences.defaults) private var dateFormat = "MM/dd/yy @ HH:mm"

    var body: some View {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: Locale.current.identifier)
        formatter.dateFormat = dateFormat
        return SectionCard("Commits", systemImage: "smallcircle.filled.circle", count: entries.count,
                           contentPadding: SidebarMetrics.cardPadding) {
            if entries.isEmpty {
                Text("No commit changed this file.")
                    .foregroundStyle(.secondary)
                    .padding(.horizontal, 6)
                    .frame(maxHeight: .infinity, alignment: .topLeading)
            } else {
                CardScrollView {
                    LazyVStack(spacing: SidebarMetrics.rowSpacing) {
                        ForEach(entries) { entry in
                            HistoryRow(entry: entry, date: formatter.string(from: entry.commit.authorDate),
                                       renamed: entry.path != path,
                                       selected: session.selection == .commit(entry.commit.hash)) {
                                session.openHistoryEntry(entry, of: tool)
                            }
                        }
                    }
                }
                .frame(maxHeight: .infinity)
            }
        }
    }
}

/// A commit of the history in two lines: the author's avatar, the summary and the short sha, then the date, the author
/// (and the file's path then, when a rename changed it). A neutral fill when its commit is selected, a hover fill
/// otherwise.
private struct HistoryRow: View {
    let entry: FileHistoryEntry
    let date: String
    /// The file had another path at this commit (`--follow` across a rename).
    let renamed: Bool
    let selected: Bool
    let action: () -> Void
    @State private var hovered = false
    /// Bumped when `AvatarStore` has a new image for this author (or the avatar mode changed).
    @State private var avatarRevision = 0
    @Environment(\.displayScale) private var displayScale

    static let avatarSize: CGFloat = 24
    static let shape = RoundedRectangle(cornerRadius: 10, style: .continuous)

    var body: some View {
        let commit = entry.commit
        HStack(spacing: 10) {
            avatar
                .id(avatarRevision)
            VStack(alignment: .leading, spacing: 2) {
                HStack(spacing: 8) {
                    Text(commit.subject)
                        .foregroundStyle(selected ? Color.primary : Color.primary.opacity(0.85))
                        .lineLimit(1)
                        .truncationMode(.tail)
                    Spacer(minLength: 8)
                    Text(String(commit.hash.prefix(7)))
                        .font(.callout.monospaced())
                        .foregroundStyle(.secondary)
                }
                HStack(spacing: 6) {
                    Text(date)
                        .monospacedDigit()
                        .lineLimit(1)
                        .fixedSize()
                    Text("by \(commit.authorName)")
                        .lineLimit(1)
                    if renamed {
                        Text(entry.path)
                            .foregroundStyle(.tertiary)
                            .lineLimit(1)
                            .truncationMode(.head)
                    }
                }
                .font(.settingsCaption)
                .foregroundStyle(.secondary)
            }
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 6)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Self.shape.fill(selected ? Palette.selectedFill : hovered ? Palette.hoverFill : .clear))
        .overlay(Self.shape.strokeBorder(selected ? Palette.selectedBorder : .clear, lineWidth: 1))
        .contentShape(Self.shape)
        .animation(Motion.hover, value: hovered)
        .onHover { hovered = $0 }
        .onTapGesture(perform: action)
        .onReceive(NotificationCenter.default.publisher(for: AvatarStore.didChange)) { note in
            guard let changed = note.userInfo?[AvatarStore.emailKey] as? String else { return avatarRevision &+= 1 }
            if AvatarStore.matches(email: commit.authorEmail, name: commit.authorName, changed: changed) {
                avatarRevision &+= 1
            }
        }
        .help(renamed ? "\(commit.subject)\n\(entry.path)" : commit.subject)
        .accessibilityElement(children: .ignore)
        .accessibilityAddTraits(selected ? [.isButton, .isSelected] : .isButton)
        .accessibilityLabel("\(commit.subject), \(commit.authorName), \(date)")
        .accessibilityAction { action() }
    }

    @ViewBuilder private var avatar: some View {
        let commit = entry.commit
        let pixels = Int((Self.avatarSize * displayScale).rounded(.up))
        if let image = AvatarStore.shared.avatar(email: commit.authorEmail, name: commit.authorName, pixels: pixels) {
            Image(nsImage: image)
                .resizable()
                .frame(width: Self.avatarSize, height: Self.avatarSize)
                .clipShape(Circle())
                .accessibilityHidden(true)
        } else {
            SkeletonLine(width: Self.avatarSize, height: Self.avatarSize)
        }
    }
}

/// The history's skeleton: the commits card with two-line rows of an avatar circle, a summary bar and the sha, then
/// the meta bars.
private struct HistoryPlaceholder: View {
    private static let widths: [CGFloat] = [0.55, 0.7, 0.4, 0.62, 0.5, 0.75, 0.35, 0.6, 0.45, 0.66, 0.52, 0.3]

    var body: some View {
        SectionCard("Commits", systemImage: "smallcircle.filled.circle", countIsLoading: true,
                    contentPadding: SidebarMetrics.cardPadding) {
            VStack(spacing: SidebarMetrics.rowSpacing) {
                ForEach(Self.widths.indices, id: \.self) { index in
                    HStack(spacing: 10) {
                        SkeletonLine(width: HistoryRow.avatarSize, height: HistoryRow.avatarSize)
                        VStack(alignment: .leading, spacing: 8) {
                            HStack(spacing: 8) {
                                SkeletonLine(fraction: Self.widths[index], height: 10)
                                Spacer(minLength: 8)
                                SkeletonLine(width: 52, height: 10)
                            }
                            SkeletonLine(width: 150, height: 8)
                        }
                    }
                    .padding(.horizontal, 10)
                    .padding(.vertical, 8)
                }
            }
            // The loaded card fills panel 1: so does its skeleton.
            .frame(maxHeight: .infinity, alignment: .top)
        }
    }
}

/// Panel 2 while a file history shows and no commit's diff is open yet: the controls card (Follow renames, close), then
/// the diff's skeleton while the history loads (its newest commit opens then), or why there is no diff (no commit
/// changed the file, a failed read).
struct FileHistoryDiffPlaceholder: View {
    let session: RepoSession
    let path: String

    var body: some View {
        VStack(spacing: SectionCardMetrics.spacing) {
            DiffControlsCard(session: session, target: nil)
            content
        }
    }

    @ViewBuilder private var content: some View {
        switch session.toolState {
        case .loaded(.history(let entries)) where entries.isEmpty:
            DiffNoticeCard(title: "File History", systemImage: "clock.arrow.circlepath",
                           message: "No commit changed \((path as NSString).lastPathComponent).")
        case .failed(let message):
            DiffNoticeCard(title: "File History", systemImage: "exclamationmark.triangle", message: message)
        default:
            SectionCard(nil, contentPadding: 0) {
                DiffPlaceholder()
            }
            .allowsHitTesting(false)
            .accessibilityElement(children: .ignore)
            .accessibilityLabel("Loading")
        }
    }
}
