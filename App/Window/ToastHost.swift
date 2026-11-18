// The window's operation toasts, at its bottom right: a user operation's outcome (a push, a pull, a fetch, a commit,
// a menu's or a dialog's write) as a short card that closes by itself after a few seconds, or at once with its x.
// Settings › General › Notifications picks which outcomes show (`ToastLevel`). A failure still shows in the repo
// tab's error banner too, with its hint and actions: the toast only says that it failed. The automatic fetch never
// shows one.
import HistqCore
import SwiftUI

/// One outcome on screen.
struct OperationToast: Identifiable, Equatable {
    /// `warning`: it ran, but something needs a look (the local changes stayed in a stash).
    enum Kind { case success, failure, warning }

    let id = UUID()
    let kind: Kind
    let title: String
    var detail: String?
    /// The tab's name, when the operation ran in a tab that is not the one on screen.
    var repo: String?

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
        case .fetchAll:
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

    /// "Push main failed" with the error banner's hint when it has one, else git's `error:` or `fatal:` line (a
    /// rejected push starts with "To <remote>"), else its first line; "Pull stopped on conflicts".
    static func failure(_ title: String, error: Error, message: String, hint: String? = nil) -> OperationToast {
        if case .conflict = error as? GitError {
            return OperationToast(kind: .failure, title: "\(title) stopped on conflicts",
                                  detail: "Resolve the conflicted files to continue.")
        }
        let lines = message.split(whereSeparator: \.isNewline).map { $0.trimmingCharacters(in: .whitespaces) }
        let line = lines.first { $0.hasPrefix("error:") || $0.hasPrefix("fatal:") } ?? lines.first
        return OperationToast(kind: .failure, title: "\(title) failed", detail: hint ?? line)
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

    /// How long it stays: long enough to read, an error or a warning a bit longer.
    var duration: Duration { kind == .success ? .seconds(3) : .seconds(6) }
}

/// Settings › General › Notifications (`PrefKey.toastLevel`).
enum ToastLevel: String, CaseIterable {
    case all, errors, off

    var title: String {
        switch self {
        case .all: "All"
        case .errors: "Errors only"
        case .off: "Off"
        }
    }

    static var current: ToastLevel {
        Preferences.defaults.string(forKey: PrefKey.toastLevel.rawValue).flatMap(ToastLevel.init) ?? .all
    }

    func shows(_ kind: OperationToast.Kind) -> Bool {
        switch self {
        case .all: true
        case .errors: kind != .success
        // A warning is the only notice that the local changes moved into a stash: no banner says it.
        case .off: kind == .warning
        }
    }
}

/// The toasts, newest at the bottom. Only the cards take clicks: the space around them reaches the panels below.
struct ToastHost: View {
    /// The most on screen at once; a new one pushes the oldest out.
    static let limit = 3

    let model: WindowModel
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        VStack(alignment: .trailing, spacing: 8) {
            ForEach(model.toasts) { toast in
                ToastCard(toast: toast) { model.dismissToast(toast.id) }
                    .transition(reduceMotion ? .opacity : .move(edge: .trailing).combined(with: .opacity))
            }
        }
        .padding(16)
        .animation(reduceMotion ? Motion.exit : Motion.standard, value: model.toasts.map(\.id))
    }
}

/// A toast: its icon, what ran, the outcome and the x.
private struct ToastCard: View {
    let toast: OperationToast
    let dismiss: () -> Void

    var body: some View {
        // Green for a success, orange for a warning, the error banner's tone for a failure.
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
                if let detail = toast.detail {
                    Text(detail)
                        .font(.settingsCaption)
                        .foregroundStyle(.secondary)
                        .lineLimit(3)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .accessibilityElement(children: .combine)
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
}
