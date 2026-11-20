// The window's operation toasts, at its bottom right: a user operation's outcome (a push, a pull, a fetch, a commit,
// a menu's or a dialog's write) as a short card that closes by itself after a few seconds, or at once with its x. A
// failure with an action ("Delete Anyway") stays until its action or its x.
// The pointer over the cards holds their timers until it leaves. Settings › General › Notifications picks whether the
// successes show (`ToastLevel`); a failure always shows, as the only place it is reported: its hint, the hint's
// action (`FailureHints`) and a button that copies git's whole message. The automatic fetch never shows one.
import AppKit
import HistqCore
import SwiftUI

/// One outcome on screen.
struct OperationToast: Identifiable, Equatable {
    /// A button on the card ("Delete Anyway"); the toast closes when it is clicked.
    struct Action {
        let title: String
        /// A red button ("Delete Anyway"), not the blue one.
        var destructive = false
        let perform: @MainActor () -> Void
    }

    /// `warning`: it ran, but something needs a look (the local changes stayed in a stash).
    enum Kind { case success, failure, warning }

    let id = UUID()
    let kind: Kind
    let title: String
    var detail: String?
    /// The tab's name, when the operation ran in a tab that is not the one on screen.
    var repo: String?
    /// A failure's whole message (git's output), which the copy button copies with the title and the detail.
    var message: String?
    var action: Action?

    static func == (lhs: OperationToast, rhs: OperationToast) -> Bool { lhs.id == rhs.id }

    /// "Push main to origin/main", with what changed (`outcome`) or "Done".
    static func success(_ title: String, detail: String? = nil) -> OperationToast {
        OperationToast(kind: .success, title: title, detail: detail ?? "Done")
    }

    /// What a push, pull or fetch changed, read from the refs before it and after it (the session reads them again
    /// after each write): "Everything up to date. Nothing to push.", "Pushed 2 commits to origin/main.", "Already up
    /// to date. Nothing to pull.", "origin/main updated; 1 new tag." Nil for other writes, or without both reads.
    static func outcome(of write: RepoSession.Write, before: Refs?, after: Refs?) -> String? {
        guard let before, let after else { return nil }
        switch write {
        case .push(let branch, let remote, let remoteBranch, _, let forceWithLease):
            let tracking = "\(remote)/\(remoteBranch ?? branch)"
            let old = before.remoteBranches.first { $0.name == tracking }?.commit
            guard let new = after.remoteBranches.first(where: { $0.name == tracking })?.commit else { return nil }
            guard let old else { return "Created \(tracking)." }
            if old == new { return "Everything up to date. Nothing to push." }
            if forceWithLease == nil, let local = before.localBranches.first(where: { $0.name == branch }),
               local.upstream == tracking, local.ahead > 0
            {
                return "Pushed \(count(local.ahead, "commit")) to \(tracking)."
            }
            return "\(tracking) is now at \(new.prefix(7))."
        case .pull:
            guard let new = after.head.commit else { return nil }
            if before.head.commit == new { return "Already up to date. Nothing to pull." }
            if case .branch(let name, _) = after.head { return "\(name) is now at \(new.prefix(7))." }
            return "HEAD is now at \(new.prefix(7))."
        case .pullBranch(let branch, _, _):
            let old = before.localBranches.first { $0.name == branch }?.commit
            guard let new = after.localBranches.first(where: { $0.name == branch })?.commit else { return nil }
            return old == new ? "Already up to date. Nothing to pull." : "\(branch) is now at \(new.prefix(7))."
        case .fetchAll, .fetchRemote:
            let old = Dictionary(before.remoteBranches.map { ($0.name, $0.commit) }, uniquingKeysWith: { a, _ in a })
            let new = Dictionary(after.remoteBranches.map { ($0.name, $0.commit) }, uniquingKeysWith: { a, _ in a })
            let updated = new.keys.filter { old[$0] != nil && old[$0] != new[$0] }.sorted()
            let added = new.keys.filter { old[$0] == nil }.count
            let removed = old.keys.filter { new[$0] == nil }.count
            let tags = Set(after.tags.map(\.name)).subtracting(before.tags.map(\.name)).count
            var parts: [String] = []
            if !updated.isEmpty {
                let names = updated.prefix(3).joined(separator: ", ")
                parts.append(updated.count > 3 ? "\(names) and \(updated.count - 3) more updated" : "\(names) updated")
            }
            if added > 0 { parts.append("\(count(added, "new branch", "new branches"))") }
            if removed > 0 { parts.append("\(count(removed, "branch", "branches")) removed") }
            if tags > 0 { parts.append("\(count(tags, "new tag"))") }
            return parts.isEmpty ? "Everything up to date. Nothing new on the remotes." : parts.joined(separator: "; ") + "."
        default:
            return nil
        }
    }

    /// "1 commit", "3 commits".
    private static func count(_ n: Int, _ one: String, _ many: String? = nil) -> String {
        "\(n) \(n == 1 ? one : many ?? one + "s")"
    }

    /// "Push main failed" with its hint (`FailureHints`) when it has one, and git's message under it (its first lines
    /// on the card, whole for the copy button); "Pull stopped on conflicts".
    static func failure(_ title: String, error: Error, message: String, hint: String? = nil,
                        action: Action? = nil) -> OperationToast
    {
        if case .conflict = error as? GitError {
            return OperationToast(kind: .failure, title: "\(title) stopped on conflicts",
                                  detail: "Resolve the conflicted files to continue.", message: message)
        }
        return OperationToast(kind: .failure, title: "\(title) failed", detail: hint, message: message, action: action)
    }

    /// What the copy button copies: the title, the hint and git's whole message.
    var copyText: String {
        ([title] + [detail, message].compactMap { $0 }).joined(separator: "\n\n")
    }

    /// A merge, rebase, cherry-pick or revert that stopped without an error (a rebase at an `edit` step): the
    /// operation banner takes over.
    static func stopped(_ title: String) -> OperationToast {
        OperationToast(kind: .failure, title: "\(title) stopped", detail: "Continue or abort it above the graph.")
    }

    /// An auto-stash that did not simply come back: "Changes kept in stash 1a2b3c4.", "Changes come back after continue
    /// or abort."
    static func warning(_ title: String, detail: String) -> OperationToast {
        OperationToast(kind: .warning, title: title, detail: detail)
    }

    /// How long it stays: long enough to read, an error or a warning a bit longer; nil with an action, which stays
    /// until it is used or closed.
    var duration: Duration? { action != nil ? nil : kind == .success ? .seconds(3) : .seconds(6) }
}

/// Settings › General › Notifications (`PrefKey.toastLevel`). There is no "off": a failure shows only in its toast.
/// A stored "off" (from before) is read as `errors` (`AppState.registerDefaults`).
enum ToastLevel: String, CaseIterable {
    case all, errors

    var title: String {
        switch self {
        case .all: "All"
        case .errors: "Errors only"
        }
    }

    static var current: ToastLevel {
        Preferences.defaults.string(forKey: PrefKey.toastLevel.rawValue).flatMap(ToastLevel.init) ?? .all
    }

    func shows(_ kind: OperationToast.Kind) -> Bool {
        switch self {
        case .all: true
        case .errors: kind != .success
        }
    }
}

/// The toasts, newest at the bottom. Only the cards take clicks: the space around them reaches the panels below. The
/// pointer over them holds every toast's timer (`WindowModel.holdToasts`) until it leaves.
struct ToastHost: View {
    /// The most on screen at once; a new one pushes the oldest out.
    static let limit = 3

    let model: WindowModel
    /// The host in Settings' layer, over Settings; the window's is under every modal. Only the one that matches
    /// `isSettingsOpen` draws the toasts, so they never show twice.
    var overSettings = false
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        VStack(alignment: .trailing, spacing: 8) {
            if model.isSettingsOpen == overSettings {
                ForEach(model.toasts) { toast in
                    ToastCard(toast: toast) { model.dismissToast(toast.id) }
                        .transition(reduceMotion ? .opacity : .move(edge: .trailing).combined(with: .opacity))
                }
            }
        }
        .onHover { model.holdToasts($0) }
        // Settings closing under the pointer removes its host without a hover end: the timers must not stay held.
        .onDisappear { model.holdToasts(false) }
        .padding(16)
        .animation(reduceMotion ? Motion.exit : Motion.standard, value: model.toasts.map(\.id))
    }
}

/// A toast: its icon, what ran, the outcome, a failure's action and copy button, and the x.
private struct ToastCard: View {
    let toast: OperationToast
    let dismiss: () -> Void
    /// The copy button shows a checkmark for a moment after a click.
    @State private var copied = false

    var body: some View {
        // Green for a success, orange for a warning, red for a failure.
        let lane = switch toast.kind { case .success: 2; case .warning: 1; case .failure: 6 }
        let tone = Color(nsColor: Palette.graphLanes[lane])
        HStack(alignment: .top, spacing: 10) {
            Image(systemName: toast.kind == .success ? "checkmark.circle.fill" : "exclamationmark.triangle.fill")
                .foregroundStyle(tone)
                .font(.system(size: 15))
                .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 2) {
                if let repo = toast.repo {
                    Text(repo)
                        .font(.settingsCaption)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }
                Text(toast.title)
                    .font(.body.weight(.semibold))
                    .lineLimit(2)
                VStack(alignment: .leading, spacing: 2) {
                    if let detail = toast.detail {
                        Text(detail)
                            .font(.settingsCaption)
                            .foregroundStyle(.secondary)
                            .fixedSize(horizontal: false, vertical: true)
                            .textSelection(.enabled)
                    }
                    // A failure's message: its first lines (the copy button copies it whole).
                    if let message = toast.message, toast.kind == .failure {
                        Text(message)
                            .font(.settingsCaption.monospaced())
                            .foregroundStyle(.secondary)
                            .lineLimit(6)
                            .fixedSize(horizontal: false, vertical: true)
                            .textSelection(.enabled)
                    }
                }
                .accessibilityElement(children: .combine)
                if let action = toast.action {
                    Button(action.title) {
                        dismiss()
                        action.perform()
                    }
                    .buttonStyle(RowTextButtonStyle(prominent: true, destructive: action.destructive))
                    .padding(.top, 4)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            if toast.message != nil {
                Button(action: copy) {
                    Image(systemName: copied ? "checkmark" : "doc.on.doc")
                        .font(.system(size: 11, weight: .semibold))
                        .foregroundStyle(.secondary)
                }
                .buttonStyle(RowIconButtonStyle())
                .help("Copy Error")
                .accessibilityLabel("Copy Error")
            }
            Button(action: dismiss) {
                Image(systemName: "xmark")
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundStyle(.secondary)
            }
            .buttonStyle(RowIconButtonStyle())
            .help("Dismiss")
            .accessibilityLabel("Dismiss")
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 10)
        .frame(width: 320)
        .modifier(GlassCard(raised: true))
        .modifier(NoticeTint(tone: tone))
    }

    private func copy() {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(toast.copyText, forType: .string)
        copied = true
        Task {
            try? await Task.sleep(for: .seconds(1.5))
            copied = false
        }
    }
}
