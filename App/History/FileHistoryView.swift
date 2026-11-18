// A file's history in panel2, in place of the graph: the header card (back, the file, "Follow renames"), then one card
// with the commits that changed it, newest first. A click on a commit selects it (panel3) and opens the file's diff at
// that commit over the history; Back or Esc there shows the history again as it was (it stays mounted, RepoLayoutView).
// The history loads off the main actor (`RepoSession.selectTool`); until then the card holds skeleton rows.
import HistqCore
import SwiftUI

/// Panel2 while a file's history is open: the header card at once, then the commits (skeletons until loaded).
struct FileHistoryView: View {
    let session: RepoSession
    /// The open tool (`.fileHistory` of `path`, `rev`, `follow`): a row's diff returns to it.
    let tool: RepoTool
    let path: String
    let rev: String?
    let follow: Bool
    @Environment(WindowModel.self) private var model

    var body: some View {
        VStack(spacing: SectionCardMetrics.spacing) {
            header
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
                            model.selectedSession === session && session.openTool == tool
                        }
                    ) {
                        HistoryPlaceholder()
                    }
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
        }
    }

    /// Back, the file's name and folder, and the "Follow renames" switch (reads the history again).
    private var header: some View {
        let name = (path as NSString).lastPathComponent
        let folder = (path as NSString).deletingLastPathComponent
        return SectionCard(nil, contentPadding: 8) {
            HStack(spacing: 8) {
                Button {
                    session.closeFile()
                } label: {
                    Image(systemName: "chevron.left")
                        .font(.system(size: 16, weight: .semibold))
                        .foregroundStyle(.secondary)
                        .frame(width: 22, height: 22)
                }
                .buttonStyle(RowIconButtonStyle())
                .keyboardShortcut(.cancelAction)
                .help("Back to the Graph (Esc)")
                .accessibilityLabel("Back to the graph")
                .padding(.leading, 4)
                IconImage("clock.arrow.circlepath")
                    .foregroundStyle(.secondary)
                    .accessibilityHidden(true)
                HStack(spacing: 4) {
                    Text(name)
                        .font(.body.weight(.semibold))
                        .lineLimit(1)
                    if !folder.isEmpty {
                        Text(folder)
                            .foregroundStyle(.secondary)
                            .lineLimit(1)
                            .truncationMode(.head)
                    }
                }
                .help(path)
                Text("History")
                    .font(.settingsCaption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                Spacer(minLength: 8)
                Toggle("Follow renames", isOn: Binding(
                    get: { follow },
                    set: { session.selectTool(.fileHistory(path: path, rev: rev, follow: $0)) }))
                    .toggleStyle(CompactSwitch())
                    .help("Also list the commits before the file was renamed (slower)")
                Text("Follow renames")
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .fixedSize()
                    .padding(.trailing, 8)
            }
            .frame(height: 32)
        }
    }
}

/// The commits of the history, one row each, in a card that fills panel2 and scrolls.
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
                                open(entry)
                            }
                        }
                    }
                }
                .frame(maxHeight: .infinity)
            }
        }
    }

    /// Selects the commit the way a graph click does (panel3 switches at once), then opens the file's diff at that
    /// commit over the history; closing the diff returns to `tool`.
    private func open(_ entry: FileHistoryEntry) {
        let hash = entry.commit.hash
        session.selectGraph([.commit(hash)])
        let file = FileChange(letter: entry.status ?? "M", path: entry.path, originalPath: entry.oldPath)
        session.selectFile(FileTarget(source: .commit(hash), file: file), returnTool: tool)
    }
}

/// A commit of the history: the author's avatar, the summary (and the file's path then, when a rename changed it),
/// the author, the short sha and the date. A neutral capsule when its commit is selected, a hover capsule otherwise.
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

    private static let avatarSize: CGFloat = 16

    var body: some View {
        let commit = entry.commit
        HStack(spacing: 8) {
            avatar
                .id(avatarRevision)
            Text(commit.subject)
                .foregroundStyle(selected ? Color.primary : Color.primary.opacity(0.85))
                .lineLimit(1)
                .truncationMode(.tail)
            if renamed {
                Text(entry.path)
                    .font(.settingsCaption)
                    .foregroundStyle(.tertiary)
                    .lineLimit(1)
                    .truncationMode(.head)
            }
            Spacer(minLength: 8)
            Text(commit.authorName)
                .foregroundStyle(.secondary)
                .lineLimit(1)
                .frame(maxWidth: 140, alignment: .trailing)
            Text(String(commit.hash.prefix(7)))
                .font(.callout.monospaced())
                .foregroundStyle(.secondary)
            Text(date)
                .font(.callout.monospacedDigit())
                .foregroundStyle(.secondary)
                .lineLimit(1)
                .fixedSize()
        }
        .padding(.horizontal, 10)
        .frame(minHeight: SidebarItemStyle.height)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Capsule().fill(selected ? Palette.selectedFill : hovered ? Palette.hoverFill : .clear))
        .overlay(Capsule().strokeBorder(selected ? Palette.selectedBorder : .clear, lineWidth: 1))
        .contentShape(Capsule())
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

/// The history's skeleton: the commits card with rows of an avatar circle, a summary bar and the meta bars.
private struct HistoryPlaceholder: View {
    private static let widths: [CGFloat] = [0.55, 0.7, 0.4, 0.62, 0.5, 0.75, 0.35, 0.6, 0.45, 0.66, 0.52, 0.3]

    var body: some View {
        SectionCard("Commits", systemImage: "smallcircle.filled.circle", countIsLoading: true,
                    contentPadding: SidebarMetrics.cardPadding) {
            VStack(spacing: SidebarMetrics.rowSpacing) {
                ForEach(Self.widths.indices, id: \.self) { index in
                    HStack(spacing: 8) {
                        SkeletonLine(width: 16, height: 16)
                        SkeletonLine(fraction: Self.widths[index], height: 10)
                        SkeletonLine(width: 80, height: 10)
                        SkeletonLine(width: 52, height: 10)
                        SkeletonLine(width: 96, height: 10)
                    }
                    .padding(.horizontal, 10)
                    .frame(height: SidebarItemStyle.height)
                }
            }
            // The loaded card fills panel2: so does its skeleton.
            .frame(maxHeight: .infinity, alignment: .top)
        }
    }
}
