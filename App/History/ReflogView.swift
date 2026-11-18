// HEAD's reflog in panel2, in place of the graph: the header card (back, "Reflog"), then one card with every move of
// HEAD, newest first: what moved it (checkout, commit, reset…), its message, the commit's short sha and the date. A
// click on an entry selects its commit in panel3 and keeps the reflog open, also for a commit no branch holds any more;
// its menu checks the commit out, branches from it or copies its sha.
// The reflog loads off the main actor (`RepoSession.selectTool`); until then the card holds skeleton rows.
import HistqCore
import SwiftUI

/// Panel2 while the reflog is open: the header card at once, then the entries (skeletons until loaded).
struct ReflogView: View {
    let session: RepoSession
    @Environment(WindowModel.self) private var model

    var body: some View {
        VStack(spacing: SectionCardMetrics.spacing) {
            header
            Group {
                switch session.toolState {
                case .loaded(.reflog(let entries)):
                    ReflogCard(session: session, entries: entries)
                        .onAppear { UITiming.content(session.toolDetail) }
                case .failed(let message):
                    DiffNoticeCard(title: "Reflog", systemImage: "exclamationmark.triangle", message: message)
                        .onAppear { UITiming.content("\(session.toolDetail) failed") }
                default:
                    PlaceholderCard(
                        token: session.toolToken, detail: session.toolDetail,
                        isCurrent: { [model, session] in
                            model.selectedSession === session && session.openTool == .reflog
                        }
                    ) {
                        ReflogPlaceholder()
                    }
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
        }
    }

    /// Back and the title.
    private var header: some View {
        SectionCard(nil, contentPadding: 8) {
            HStack(spacing: 8) {
                // Closes the reflog, and a diff opened from it (Columns shows both). Esc goes to that diff's close
                // first.
                Button {
                    session.closePanel2()
                } label: {
                    Image(systemName: "chevron.left")
                        .font(.system(size: 16, weight: .semibold))
                        .foregroundStyle(.secondary)
                        .frame(width: 22, height: 22)
                }
                .buttonStyle(RowIconButtonStyle())
                .keyboardShortcut(session.openFile == nil ? .cancelAction : nil)
                .help("Back to the Graph (Esc)")
                .accessibilityLabel("Back to the graph")
                .padding(.leading, 4)
                IconImage("clock.arrow.2.circlepath")
                    .foregroundStyle(.secondary)
                    .accessibilityHidden(true)
                Text("Reflog")
                    .font(.body.weight(.semibold))
                    .lineLimit(1)
                Text("HEAD")
                    .font(.settingsCaption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                Spacer(minLength: 8)
            }
            .frame(height: 32)
        }
    }
}

/// The entries, one row each, in a card that fills panel2 and scrolls.
private struct ReflogCard: View {
    let session: RepoSession
    let entries: [ReflogEntry]
    @AppStorage(PrefKey.dateFormat.rawValue, store: Preferences.defaults) private var dateFormat = "MM/dd/yy @ HH:mm"

    var body: some View {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: Locale.current.identifier)
        formatter.dateFormat = dateFormat
        return SectionCard("Entries", systemImage: "smallcircle.filled.circle", count: entries.count,
                           contentPadding: SidebarMetrics.cardPadding) {
            if entries.isEmpty {
                Text("HEAD has no reflog.")
                    .foregroundStyle(.secondary)
                    .padding(.horizontal, 6)
                    .frame(maxHeight: .infinity, alignment: .topLeading)
            } else {
                CardScrollView {
                    LazyVStack(spacing: SidebarMetrics.rowSpacing) {
                        ForEach(entries) { entry in
                            ReflogRow(entry: entry, date: formatter.string(from: entry.date),
                                      selected: session.selection == .commit(entry.hash)) {
                                session.selectKeepingTool(entry.hash)
                            }
                            .contextMenu { MenuEntriesView(entries: RepoMenus.reflog(entry.hash, session)) }
                        }
                    }
                }
                .frame(maxHeight: .infinity)
            }
        }
    }
}

/// An entry: the action, the message, the short sha and the date. A neutral capsule when its commit is selected, a
/// hover capsule otherwise.
private struct ReflogRow: View {
    let entry: ReflogEntry
    let date: String
    let selected: Bool
    let action: () -> Void
    @State private var hovered = false

    var body: some View {
        HStack(spacing: 8) {
            Text(entry.action)
                .foregroundStyle(.secondary)
                .lineLimit(1)
                .frame(width: 120, alignment: .leading)
            Text(entry.message)
                .foregroundStyle(selected ? Color.primary : Color.primary.opacity(0.85))
                .lineLimit(1)
                .truncationMode(.tail)
            Spacer(minLength: 8)
            Text(String(entry.hash.prefix(7)))
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
        .help("HEAD@{\(entry.index)}: \(entry.action): \(entry.message)")
        .accessibilityElement(children: .ignore)
        .accessibilityAddTraits(selected ? [.isButton, .isSelected] : .isButton)
        .accessibilityLabel("\(entry.action), \(entry.message), \(date)")
        .accessibilityAction { action() }
    }
}

/// The reflog's skeleton: the entries card with rows of an action bar, a message bar and the meta bars.
private struct ReflogPlaceholder: View {
    private static let widths: [CGFloat] = [0.55, 0.7, 0.4, 0.62, 0.5, 0.75, 0.35, 0.6, 0.45, 0.66, 0.52, 0.3]

    var body: some View {
        SectionCard("Entries", systemImage: "smallcircle.filled.circle", countIsLoading: true,
                    contentPadding: SidebarMetrics.cardPadding) {
            VStack(spacing: SidebarMetrics.rowSpacing) {
                ForEach(Self.widths.indices, id: \.self) { index in
                    HStack(spacing: 8) {
                        SkeletonLine(width: 80, height: 10)
                            .frame(width: 120, alignment: .leading)
                        SkeletonLine(fraction: Self.widths[index], height: 10)
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
