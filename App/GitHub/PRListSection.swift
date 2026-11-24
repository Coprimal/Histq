// The sidebar's PRs tab: the repo's GitHub lists in their own cards (My PRs, Review requested, All open, Issues
// assigned to me), or the Connect GitHub card without a connected account. A row shows the number, title, author
// avatar, a draft capsule and the checks state; a click selects it at once and panel2 shows its placeholder in the same
// frame. Also `GitHubDriver`, which keeps the tab's `HostingStore` running while the repo tab shows (the graph's PR
// badges need its lists too).
import AppKit
import HistqCore
import SwiftUI

/// Drives the tab's `HostingStore` while the repo tab shows: `watch` resolves the connection, reads the lists once (the
/// graph's PR badges), and keeps them fresh while the PRs tab shows; it restarts when the profile, the remotes, the
/// window's visibility, the shown tab (`tabIsShown`) or the sidebar tab change, stops when the repo tab or the window
/// goes away, and pauses while the window is hidden or covered or a kept-alive tab is not shown. Draws nothing.
struct GitHubDriver: View {
    let session: RepoSession
    @Environment(WindowModel.self) private var model
    @Environment(WindowState.self) private var windowState
    @Environment(\.tabIsShown) private var tabIsShown
    @AppStorage(PrefKey.sidebarSectionOrder.rawValue, store: Preferences.defaults) private var sectionOrder = ""
    @AppStorage(PrefKey.hiddenSidebarSections.rawValue, store: Preferences.defaults) private var hiddenSections = ""

    var body: some View {
        Color.clear
            .accessibilityHidden(true)
            .task(id: source) { [session, source] in
                await session.github.watch(source, profile: session.profile)
            }
            .onReceive(NotificationCenter.default.publisher(for: NSApplication.didBecomeActiveNotification)) { _ in
                if windowState.isVisible, tabIsShown, listsShown { session.github.refreshIfStale() }
            }
            // The store reads only the shown lists: a list shown again loads now, not at the next refresh. Only in the
            // shown tab: the setting is app-wide, and the kept-alive tabs must not all read GitHub at once.
            .onChange(of: layout.pullRequestLists) { old, new in
                if tabIsShown, new.contains(where: { !old.contains($0) }) { session.github.refreshNow() }
            }
    }

    private var layout: SidebarSections { SidebarSections(order: sectionOrder, hidden: hiddenSections) }

    /// The sidebar shows the PRs tab (not hidden, `SidebarSections`).
    private var listsShown: Bool { layout.shownTab(session.sidebarTab) == .prs }

    private var source: HostingStore.Source {
        let profile = session.profile
        #if DEBUG
        let isStub = GitHubStub.isEnabled
        #else
        let isStub = false
        #endif
        // A store that failed to load reads as no profile: the Connect card, whose Settings page shows the failure.
        let profilesLoaded = switch ProfileLibrary.shared.state {
        case .loaded, .failed: true
        case .idle, .loading: false
        }
        return HostingStore.Source(
            profilesLoaded: profilesLoaded, profileID: profile?.id, accounts: profile?.accounts ?? [],
            remotes: session.remotes, remotesKnown: session.refs.value != nil, settingsOpen: model.isSettingsOpen,
            windowVisible: windowState.isVisible, listsShown: listsShown, isShown: tabIsShown, isStub: isStub)
    }
}

/// The PRs tab's cards, the shown lists in the user's order (`SidebarSections`); `GitHubDriver` keeps their lists
/// fresh while they show.
struct PullRequestSections: View {
    let session: RepoSession
    @AppStorage(PrefKey.sidebarSectionOrder.rawValue, store: Preferences.defaults) private var sectionOrder = ""
    @AppStorage(PrefKey.hiddenSidebarSections.rawValue, store: Preferences.defaults) private var hiddenSections = ""
    @Environment(\.textSize) private var textSize

    var body: some View {
        let store = session.github
        let lists = SidebarSections(order: sectionOrder, hidden: hiddenSections).pullRequestLists
        VStack(alignment: .leading, spacing: SidebarMetrics.cardSpacing) {
            if let notice = store.actionNotice {
                PRActionErrorCard(message: notice) { store.actionNotice = nil }
                    .onAppear { UITiming.content("prs notice \(notice)") }
            }
            switch store.connection {
            case .resolving:
                ForEach(lists, id: \.self) { list in
                    ListCard(session: session, list: list, avatars: .drawn)
                }
            case .notConnected(let account):
                ConnectGitHubCard(account: account, host: session.hostedRemoteHost)
            case .noRemote where session.hostedRemoteHost != nil:
                // A remote names a hosted repository on a host the profile has no account for.
                ConnectGitHubCard(account: nil, host: session.hostedRemoteHost)
            case .noRemote:
                SectionCard("Integrations", systemImage: "exclamationmark.triangle") {
                    VStack(alignment: .leading, spacing: 4) {
                        Text("No connected remote")
                            .font(textSize.bodyMedium)
                        Text("No remote of this repository has a connected account.")
                            .font(textSize.caption)
                            .foregroundStyle(.secondary)
                            .fixedSize(horizontal: false, vertical: true)
                        if let hint = session.sshRemoteHint {
                            Text("\(hint.name) uses SSH on \(hint.host): connect an account for that host in "
                                + "Settings › Integrations. Host aliases from ~/.ssh/config are not matched to accounts.")
                                .font(textSize.caption)
                                .foregroundStyle(.secondary)
                                .fixedSize(horizontal: false, vertical: true)
                        }
                    }
                }
            case .connected:
                // A provider without issues has no Issues list (`HostingStore` does not read it either).
                ForEach(lists.filter { $0 != .assigned || store.offers(.issues) }, id: \.self) { list in
                    ListCard(session: session, list: list, avatars: .of(store))
                }
            }
        }
    }
}

/// One list in its own collapsible card: skeleton rows until its first read, the read's error above the rows it
/// kept, then the rows.
private struct ListCard: View {
    let session: RepoSession
    let list: HostingStore.List
    /// Where the authors' avatars come from (`HostAvatars.of` the repository).
    let avatars: HostAvatars
    /// The header's search (`CardSearchButton`): the field above the rows, which then show only the matching ones.
    @State private var isSearching = false
    @State private var query = ""

    var body: some View {
        let store = session.github
        let state = store.lists[list]
        // A list with no rows (and no error to show) stays collapsed, as the other sidebar cards.
        let isEmpty = state?.rows?.isEmpty == true && state?.error == nil
        let isExpanded = Binding(get: { !isEmpty && !store.collapsed.contains(list) },
                                 set: {
                                     guard !isEmpty else { return }
                                     if $0 { store.collapsed.remove(list) } else { store.collapsed.insert(list) }
                                 })
        let kind = store.kind
        SectionCard(list.title(kind), systemImage: list.systemImage, count: state?.rows?.count,
                    countIsLoading: state?.rows == nil && state?.error == nil,
                    isExpanded: isExpanded, contentPadding: SidebarMetrics.cardPadding) {
            VStack(alignment: .leading, spacing: SidebarMetrics.rowSpacing) {
                if isSearching {
                    CardSearchField(prompt: "Filter by title or number", isSearching: $isSearching, query: $query)
                }
                if let error = state?.error {
                    ListErrorRow(error: error)
                }
                if let rows = state?.rows {
                    let shown = isSearching ? rows.filter { matches($0) } : rows
                    if rows.isEmpty, state?.error == nil { EmptyRow(text: list.emptyText(kind)) }
                    if shown.isEmpty, !rows.isEmpty { EmptyRow(text: "No matches") }
                    ForEach(shown) { row in
                        HostedRowView(session: session, row: row, checks: row.headSHA.flatMap { store.checks[$0] },
                                      avatars: avatars)
                    }
                } else if state?.error == nil {
                    SkeletonRows(fractions: list == .allOpen ? [0.7, 0.5, 0.6] : [0.6, 0.45])
                }
            }
        } accessory: {
            if state?.rows != nil, !isEmpty {
                CardSearchButton(title: list.title(kind), isSearching: $isSearching, query: $query,
                                 isExpanded: isExpanded)
            }
        }
        #if DEBUG
        .task(id: state?.rows != nil) {
            guard state?.rows != nil, AppState.launchFlag("-HistqToggleCard") == list.rawValue else { return }
            await Self.debugToggle(isExpanded, list: list)
        }
        #endif
    }

    #if DEBUG
    /// DEBUG `-HistqToggleCard <list>` (`mine`, `reviewRequested`…): once the list has rows, collapses and expands
    /// its card four times, 1.5 s apart, as a click on its header does, and logs each toggle's time to the next
    /// main-queue turn (`card-toggle <list> <collapse|expand> <ms>`).
    private static func debugToggle(_ isExpanded: Binding<Bool>, list: HostingStore.List) async {
        for _ in 0..<4 {
            guard (try? await Task.sleep(for: .seconds(1.5))) != nil else { return }
            let start = DispatchTime.now().uptimeNanoseconds
            let word = isExpanded.wrappedValue ? "collapse" : "expand"
            withAnimation(Motion.toggle) { isExpanded.wrappedValue.toggle() }
            DispatchQueue.main.async {
                let ms = Double(DispatchTime.now().uptimeNanoseconds &- start) / 1_000_000
                UITiming.probe("card-toggle", "\(list.rawValue) \(word) \(String(format: "%.1f", ms))")
            }
        }
    }
    #endif

    /// By its title or its number (`#12` or `12`; GitLab's merge requests `!12`).
    private func matches(_ row: HostedRow) -> Bool {
        FileSearch.matches("\(session.github.kind.reference(row.item)) \(row.title)", query: query)
    }
}

extension HostingStore {
    /// The connected provider's kind, whose words the PRs tab and the detail use; GitHub while none is connected.
    var kind: HostingKind { api?.client.kind ?? .github }
}

extension HostingKind {
    /// `#12` for an issue, the kind's `numberPrefix` for a pull request (`!12` on GitLab).
    func reference(_ item: HostedItem) -> String {
        switch item {
        case .pullRequest(let number): numberPrefix + String(number)
        case .issue(let number): "#\(number)"
        }
    }
}

extension HostingStore.List {
    /// `title` in the kind's words ("My MRs" on GitLab).
    func title(_ kind: HostingKind) -> String {
        self == .mine ? "My \(kind.shortNoun)s" : title
    }

    /// `emptyText` in the kind's words ("No open merge requests" on GitLab).
    func emptyText(_ kind: HostingKind) -> String {
        switch self {
        case .mine: "No open \(kind.pullRequestsNoun.lowercased()) of yours"
        case .allOpen: "No open \(kind.pullRequestsNoun.lowercased())"
        case .reviewRequested, .assigned: emptyText
        }
    }
}

/// A failed read: GitHub's reason, and for a refused token the way to reconnect.
private struct ListErrorRow: View {
    let error: HostingStore.ListError
    @Environment(WindowModel.self) private var model
    @Environment(\.textSize) private var textSize

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Label(error.message, systemImage: "exclamationmark.triangle")
                .font(textSize.caption)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            if error.reconnect {
                Text("Reconnect in Settings › Integrations.")
                    .font(textSize.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                Button("Reconnect") { model.selectSettings(.integrations) }
                    .buttonStyle(RowTextButtonStyle())
            }
        }
        .padding(.leading, SidebarMetrics.rowLeading)
        .padding(.trailing, 10)
        .padding(.vertical, 4)
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

/// Without a connected account: what is missing, and the button to Settings › Integrations.
private struct ConnectGitHubCard: View {
    /// Set when the profile has an account whose token is not in the Keychain.
    let account: HostingAccount?
    /// `RepoSession.hostedRemoteHost`; nil when no remote names a host an account can be connected for.
    let host: String?
    @Environment(WindowModel.self) private var model
    @Environment(\.textSize) private var textSize

    var body: some View {
        SectionCard(account?.providerName ?? "Integrations", systemImage: "person.crop.circle.badge.plus") {
            VStack(alignment: .leading, spacing: 8) {
                Text(account.map { "Reconnect \($0.providerName)" } ?? "Connect an account")
                    .font(textSize.bodyMedium)
                Text(detail)
                    .font(textSize.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                Button(account == nil ? connectTitle : "Reconnect") { model.selectSettings(.integrations) }
                    .buttonStyle(RowTextButtonStyle(prominent: true))
                    .help("Settings › Integrations")
            }
        }
    }

    private var connectTitle: String {
        host.map { "Connect an account for \($0)…" } ?? "Connect an account…"
    }

    private var detail: String {
        guard let account else {
            return "Pull requests and issues of this repository show here once this tab's profile has an account for "
                + (host ?? "its host") + "."
        }
        return "The token of \(account.login) on \(account.host) is not in the Keychain."
    }
}

extension RepoSession {
    /// The host of the first https remote (origin first) whose URL names a hosted repository on a host an account
    /// can be connected for; nil when none does. Never an ssh remote's host, which may be an SSH alias from
    /// `~/.ssh/config` (`git@github.com-work:…`), nor a host the profile has an account on under another port.
    var hostedRemoteHost: String? {
        let accountNames = Set((profile?.accounts ?? []).map { Self.hostName($0.host) })
        return orderedRemotes.lazy.filter { $0.url.lowercased().hasPrefix("https://") }
            .compactMap { Self.hostedHost($0.url) }
            .first { !accountNames.contains(Self.hostName($0)) }
    }

    /// The name and host of the first ssh remote (origin first) whose URL names a hosted repository; nil when none
    /// does.
    var sshRemoteHint: (name: String, host: String)? {
        orderedRemotes.lazy.filter { !$0.url.lowercased().hasPrefix("https://") }
            .compactMap { remote in Self.hostedHost(remote.url).map { (remote.name, $0) } }
            .first
    }

    /// The host of a remote URL whose path can name a hosted repository (at least two segments: GitHub's
    /// `owner/repo`, GitLab's `group/sub/project`); nil otherwise.
    private static func hostedHost(_ url: String) -> String? {
        RemoteURL(url).flatMap { $0.segments.count >= 2 ? $0.host : nil }
    }

    private var orderedRemotes: [RemoteInfo] {
        remotes.filter { $0.name == "origin" } + remotes.filter { $0.name != "origin" }
    }

    /// `host` without its `:port`, lowercase.
    private static func hostName(_ host: String) -> Substring {
        host.lowercased().split(separator: ":", maxSplits: 1, omittingEmptySubsequences: false)[0]
    }
}

/// A pull request's or an issue's row: the author's avatar, the number, the title, then a draft capsule and the
/// checks state. A click selects it and panel2 shows it at once; there is no double-click action.
private struct HostedRowView: View {
    let session: RepoSession
    let row: HostedRow
    let checks: ChecksState?
    let avatars: HostAvatars
    @State private var hovered = false
    /// Bumped when `AvatarStore` has a new image for this author (or the avatar mode changed).
    @State private var avatarRevision = 0
    @Environment(\.displayScale) private var displayScale
    @Environment(\.textSize) private var textSize

    private static let avatarSize: CGFloat = 16

    var body: some View {
        let selected = session.openHosted == row.item
        let reference = session.github.kind.reference(row.item)
        HStack(spacing: SidebarMetrics.iconGap) {
            avatar
                .id(avatarRevision)
                .frame(width: SidebarMetrics.iconSlot, alignment: .leading)
            HStack(spacing: 4) {
                Text(reference)
                    .font(textSize.caption)
                    .monospacedDigit()
                    .foregroundStyle(.secondary)
                Text(row.title)
                    .font(textSize.body)
                    .lineLimit(1)
                    .truncationMode(.tail)
                Spacer(minLength: 4)
                if row.isDraft {
                    Text("Draft")
                        .font(textSize.caption)
                        .padding(.horizontal, 6)
                        .frame(height: textSize.scaled(16))
                        .background(Capsule().fill(Palette.tabFill))
                }
                if let checks { ChecksIcon(state: checks) }
            }
        }
        .foregroundStyle(selected ? Color.primary : Color.secondary)
        // `BranchRow`'s look: a neutral capsule when selected, a hover capsule otherwise.
        .padding(.leading, SidebarMetrics.capsuleLeading)
        .padding(.trailing, 10)
        .frame(minHeight: SidebarMetrics.rowHeight(textSize))
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Capsule().fill(selected ? Palette.selectedFill : hovered ? Palette.hoverFill : .clear))
        .overlay(Capsule().strokeBorder(selected ? Palette.selectedBorder : .clear, lineWidth: 1))
        .contentShape(Capsule())
        .padding(.leading, SidebarMetrics.rowLeading - SidebarMetrics.capsuleLeading)
        .animation(Motion.hover, value: hovered)
        .onHover { hovered = $0 }
        .onTapGesture { session.selectHosted(row.item) }
        .onReceive(NotificationCenter.default.publisher(for: AvatarStore.didChange)) { note in
            guard let changed = note.userInfo?[AvatarStore.emailKey] as? String else { return avatarRevision &+= 1 }
            if authorAvatars.matches(changed, login: login, id: row.authorID, avatarURL: row.authorAvatarURL) {
                avatarRevision &+= 1
            }
        }
        .help(row.authorLogin.map { "\(row.title)\n\(reference) by \($0)" } ?? "\(row.title)\n\(reference)")
        .accessibilityElement(children: .ignore)
        .accessibilityAddTraits(selected ? [.isButton, .isSelected] : .isButton)
        .accessibilityLabel(accessibilityText)
        .accessibilityAction { session.selectHosted(row.item) }
    }

    private var login: String { row.authorLogin ?? "?" }

    /// The repository's avatars (GitHub's load in every mode, so an account looks the same here and on the pull
    /// request page); a drawn avatar, never a request, without an author.
    private var authorAvatars: HostAvatars { row.authorLogin == nil ? .drawn : avatars }

    @ViewBuilder private var avatar: some View {
        let pixels = Int((Self.avatarSize * displayScale).rounded())
        let image = authorAvatars.image(login: login, id: row.authorID, avatarURL: row.authorAvatarURL, pixels: pixels)
        if let image {
            Image(nsImage: image)
                .resizable()
                .frame(width: Self.avatarSize, height: Self.avatarSize)
                .clipShape(Circle())
                .accessibilityHidden(true)
        } else {
            SkeletonLine(width: Self.avatarSize, height: Self.avatarSize)
        }
    }

    private var accessibilityText: String {
        let kind = if case .issue = row.item { "Issue" } else { session.github.kind.pullRequestNoun }
        var parts = ["\(kind) \(row.number)", row.title]
        if let author = row.authorLogin { parts.append("by \(author)") }
        if row.isDraft { parts.append("draft") }
        if let checks { parts.append(ChecksIcon.text(checks)) }
        return parts.joined(separator: ", ")
    }
}

/// The checks state as a small icon: green check, red cross, or a yellow dotted circle while runs are unfinished.
private struct ChecksIcon: View {
    let state: ChecksState
    @Environment(\.textSize) private var textSize

    var body: some View {
        Image(systemName: symbol)
            .font(textSize.caption)
            // The diff's added/removed signs and the conflict editor's B color: the palette's green, red and yellow.
            .foregroundStyle(Color(nsColor: color))
            .help(Self.text(state))
    }

    private var symbol: String {
        switch state {
        case .success: "checkmark.circle.fill"
        case .failure: "xmark.circle.fill"
        case .pending: "circle.dotted"
        }
    }

    private var color: NSColor {
        switch state {
        case .success: Palette.diffAddedSign
        case .failure: Palette.diffRemovedSign
        case .pending: Palette.conflictB
        }
    }

    static func text(_ state: ChecksState) -> String {
        switch state {
        case .success: "checks passed"
        case .failure: "checks failed"
        case .pending: "checks running"
        }
    }
}
