// One repo tab's GitHub side, behind the sidebar's PRs tab and the graph's PR badges: which GitHub repository the tab's
// remotes name, with the tab profile's account and token, and its four lists (My PRs, Review requested, All open,
// Issues assigned to me), kept between visits of the tab. The repo tab drives it while it shows (`watch`, from
// `GitHubDriver`): a first load for the badges, a load when the window shows again and the last one is older than
// `staleAfter`, and one every `refreshInterval` only while the PRs tab shows; none once the repo tab closes or there is
// no connected account. Every request runs off the main actor; the token is read there too and only lives inside the
// provider client (`HostingProvider`), never in observable state.
import Foundation
import HistqCore
import os

/// A row of the PRs tab: a pull request or an issue, as much of it as the row draws.
struct HostedRow: Identifiable, Equatable, Sendable {
    let item: HostedItem
    let title: String
    let authorLogin: String?
    let authorID: Int?
    /// The API's avatar URL of the author (`HostAvatars.gitlab` loads it).
    let authorAvatarURL: String?
    let isDraft: Bool
    /// A pull request's head commit, whose check runs give the row's checks state; nil for an issue, or a search hit
    /// that is not in the All open list.
    let headSHA: String?

    var id: HostedItem { item }
    var number: Int { item.number }
}

extension HostedRow {
    init(pull: HostedPullRequest) {
        self.init(item: .pullRequest(pull.number), title: pull.title, authorLogin: pull.user?.login,
                  authorID: pull.user?.id, authorAvatarURL: pull.user?.avatarURL, isDraft: pull.draft ?? false,
                  headSHA: pull.head.sha)
    }

    /// A search hit (issue-shaped): the pull request, when All open has it, gives the head commit.
    init(searchHit hit: HostedIssue, pull: HostedPullRequest?) {
        self.init(item: hit.isPullRequest ? .pullRequest(hit.number) : .issue(hit.number), title: hit.title,
                  authorLogin: hit.user?.login, authorID: hit.user?.id, authorAvatarURL: hit.user?.avatarURL,
                  isDraft: hit.draft ?? pull?.draft ?? false, headSHA: pull?.head.sha)
    }
}

extension HostedItem {
    /// The timing log's detail: `pr 1`, `issue 2`.
    var timingDetail: String {
        switch self {
        case .pullRequest(let number): "pr \(number)"
        case .issue(let number): "issue \(number)"
        }
    }
}

/// A pull request's check runs, summed up: any failed run fails, any unfinished one is pending.
enum ChecksState: Equatable, Sendable {
    case success, failure, pending

    /// nil when the commit has no check runs.
    init?(_ runs: [HostedCheckRun]) {
        guard !runs.isEmpty else { return nil }
        let failed: Set<String> = ["failure", "timed_out", "cancelled", "action_required", "startup_failure"]
        if runs.contains(where: { failed.contains($0.conclusion ?? "") }) {
            self = .failure
        } else if runs.contains(where: { $0.status != "completed" }) {
            self = .pending
        } else {
            self = .success
        }
    }
}

@Observable
@MainActor
final class HostingStore {
    enum List: String, CaseIterable, Sendable {
        case mine, reviewRequested, allOpen, assigned

        var title: String {
            switch self {
            case .mine: "My PRs"
            case .reviewRequested: "Review requested"
            case .allOpen: "All open"
            case .assigned: "Issues"
            }
        }

        var systemImage: String {
            switch self {
            case .mine: "person"
            case .reviewRequested: "eye"
            case .allOpen: "lucide-git-pull-request-arrow"
            case .assigned: "smallcircle.filled.circle"
            }
        }

        var emptyText: String {
            switch self {
            case .mine: "No open pull requests of yours"
            case .reviewRequested: "No review requests"
            case .allOpen: "No open pull requests"
            case .assigned: "No open issues assigned to you"
            }
        }
    }

    enum Connection: Equatable {
        /// The profiles, the remotes or the token are still being read.
        case resolving
        /// No profile, no account on it, or (`account` set) its token is not in the Keychain: the Connect card.
        case notConnected(account: HostingAccount?)
        /// Connected, but no remote of the repo is on an account's host (`host`: the profile's first account's).
        case noRemote(host: String)
        case connected(HostedRepository)
    }

    /// Why a list could not be read; `reconnect` when GitHub refused the token.
    struct ListError: Equatable {
        let message: String
        let reconnect: Bool
    }

    /// A list's rows (nil until the first read) and the last read's error, shown above the rows it kept.
    struct ListState: Equatable {
        var rows: [HostedRow]?
        var error: ListError?
    }

    /// What `watch` resolves from: the PRs tab's `.task(id:)` key, so any change restarts it.
    struct Source: Equatable, Sendable {
        var profilesLoaded: Bool
        var profileID: UUID?
        var accounts: [HostingAccount]
        /// The tab's remotes; `remotesKnown` false until the first refs read has listed them.
        var remotes: [RemoteInfo]
        var remotesKnown: Bool
        /// Settings closing resolves again: a reconnect of the same account changes no other value, only the token.
        var settingsOpen: Bool
        /// The window shows on screen (`WindowState`): no refresh while it is hidden, minimized or covered, and
        /// one (when stale) as it shows again.
        var windowVisible: Bool
        /// The sidebar shows the PRs tab: only then do the lists refresh every `refreshInterval`.
        var listsShown: Bool
        /// The repo tab is the shown one (`tabIsShown`): a kept-alive tab that is not shown does not refresh, and
        /// refreshes (when stale) as it shows again.
        var isShown: Bool
        var isStub: Bool

        /// The source without what only decides the polling (`windowVisible`, `listsShown`, `isShown`).
        var withoutPolling: Source {
            var source = self
            source.windowVisible = false
            source.listsShown = false
            source.isShown = false
            return source
        }
    }

    /// The lists' refresh while the PRs tab shows.
    static let refreshInterval: Duration = .seconds(120)
    /// A visit of the PRs tab (or the app becoming active) reloads lists older than this.
    static let staleAfter: TimeInterval = 30
    /// The most head commits whose check runs one refresh reads (one request each): My PRs and Review requested
    /// first, then All open from the top.
    static let maxCheckedCommits = 20

    private(set) var connection: Connection = .resolving
    private(set) var lists: [List: ListState] = [:]
    /// The checks state by head commit; absent while unknown or when the commit has no check runs.
    private(set) var checks: [String: ChecksState] = [:]
    /// The cards' collapsed sections, kept between visits.
    var collapsed: Set<List> = []
    /// The open pull requests whose head branch is in the tab's repository, by that branch's remote-tracking name on
    /// the GitHub remote (`origin/feature`): the graph's PR badges. A fork's pull request is left out: its head is in
    /// another repository, so a branch of the same name here is not its head.
    private(set) var branchPullRequests: [String: RefBadge.PullRequest] = [:]
    /// A pull request or issue action that failed after its detail gave way to another one (or closed): above the PRs
    /// tab's lists, naming the number, until dismissed or replaced by the next one.
    var actionNotice: String?

    @ObservationIgnored private var client: (any HostingProvider)?
    /// The source `client`'s token was read for, without the polling flags: the same one again keeps the client, so
    /// the window showing or the PRs tab opening does not read the Keychain.
    @ObservationIgnored private var clientSource: Source?
    /// The profile, account and repository the lists belong to; another one clears them.
    @ObservationIgnored private var identity: Identity?
    /// Bumped by every resolve and refresh: a late answer of an older one is dropped.
    @ObservationIgnored private var resolveGeneration = 0
    @ObservationIgnored private var refreshGeneration = 0
    @ObservationIgnored private var lastRefresh: Date?
    /// After a rate limit: no request before this.
    @ObservationIgnored private var pausedUntil: Date?
    /// Head commits whose checks all passed: not read again. A failure is read again, since a re-run on the same head
    /// may pass.
    @ObservationIgnored private var settledChecks: Set<String> = []
    /// A refresh started outside `watch` (the app became active); cancelled by `stop`.
    @ObservationIgnored private var refreshTask: Task<Void, Never>?

    private struct Identity: Equatable {
        let profileID: UUID?
        let account: HostingAccount?
        let repository: HostedRepository
        /// The remote whose URL names `repository`: a pull request's Checkout locally fetches from it.
        let remote: String
    }

    private static let logger = Logger(subsystem: "com.math2it.histq", category: "github")

    deinit {
        refreshTask?.cancel()
    }

    /// The tab closed: no refresh runs any more.
    func stop() {
        refreshTask?.cancel()
        refreshTask = nil
        refreshGeneration &+= 1
        resolveGeneration &+= 1
    }

    // MARK: Driving

    /// Runs while the repo tab shows (`GitHubDriver`'s `.task(id: source)`): resolves the connection, loads the lists
    /// when they were never read or are stale, then, while the PRs tab shows, every `refreshInterval` until cancelled.
    /// Returns at once when not connected; returns after the first load while the window is not visible (a background
    /// launch still gets its lists), the repo tab is a kept-alive one that is not shown, or the PRs tab is not shown
    /// (the badges need one read, not polling).
    func watch(_ source: Source, profile: Profile?) async {
        await resolve(source, profile: profile)
        guard case .connected = connection, !Task.isCancelled else { return }
        // A list GitHub refused the token for loads again at once: the account may just have been reconnected.
        let refused = lists.values.contains { $0.error?.reconnect == true }
        if lastRefresh == nil || (source.windowVisible && source.isShown && (isStale || refused)) { await refresh() }
        guard source.windowVisible, source.isShown, source.listsShown else { return }
        while (try? await Task.sleep(for: Self.refreshInterval)) != nil {
            await refresh()
        }
    }

    /// The app became active while the PRs tab shows: reloads stale lists.
    func refreshIfStale() {
        guard case .connected = connection, isStale else { return }
        refreshTask?.cancel()
        refreshTask = Task { [weak self] in await self?.refresh() }
    }

    private var isStale: Bool {
        lastRefresh.map { Date.now.timeIntervalSince($0) > Self.staleAfter } ?? true
    }

    /// Whether a list has been read (rows or an error): DEBUG `-HistqSelect pr:<n>` waits for All open.
    func isRead(_ list: List) -> Bool {
        lists[list].map { $0.rows != nil || $0.error != nil } ?? false
    }

    /// The row of `item` in any list.
    func row(for item: HostedItem) -> HostedRow? {
        for list in List.allCases {
            if let row = lists[list]?.rows?.first(where: { $0.item == item }) { return row }
        }
        return nil
    }

    /// The item numbered `number`: a pull request unless only the Issues list has it.
    func item(numbered number: Int) -> HostedItem {
        row(for: .pullRequest(number))?.item ?? row(for: .issue(number))?.item ?? .pullRequest(number)
    }

    // MARK: Resolving

    private func resolve(_ source: Source, profile: Profile?) async {
        resolveGeneration &+= 1
        let generation = resolveGeneration
        #if DEBUG
        if source.isStub {
            // GitHub's stub, or GitLab's with `-HistqHostingStubKind gitlab`.
            let stub = GitHubStub.hosting()
            client = stub.client
            // The fixtures' origin names no hosted repository; a stub checkout fetches from it (and fails there).
            return connect(Identity(profileID: nil, account: nil, repository: stub.repository, remote: "origin"))
        }
        #endif
        guard source.profilesLoaded else { return setConnection(.resolving) }
        guard let profile, let first = profile.accounts.first else { return disconnect(.notConnected(account: nil)) }
        guard source.remotesKnown else { return setConnection(.resolving) }
        guard let (remote, repository, account) = Self.remote(in: source.remotes, profile: profile) else {
            return disconnect(.noRemote(host: first.host))
        }
        let identity = Identity(profileID: profile.id, account: account, repository: repository, remote: remote)
        // Settings closing (`settingsOpen`) still reads the token again: a reconnect changes nothing else. So does a
        // list GitHub refused the token for.
        let key = source.withoutPolling
        if client != nil, identity == self.identity, key == clientSource,
           !lists.values.contains(where: { $0.error?.reconnect == true })
        {
            return connect(identity)
        }
        if identity != self.identity {
            // The cards show skeletons, never the last account's or repository's rows, while the token is read.
            self.identity = nil
            forgetLists()
            setConnection(.resolving)
        }
        let client = await Self.makeClient(profileID: profile.id, account: account)
        guard generation == resolveGeneration, !Task.isCancelled else { return }
        guard let client else { return disconnect(.notConnected(account: account)) }
        self.client = client
        clientSource = key
        connect(identity)
    }

    private func connect(_ identity: Identity) {
        if identity != self.identity { forgetLists() }
        self.identity = identity
        setConnection(.connected(identity.repository))
    }

    private func disconnect(_ connection: Connection) {
        client = nil
        clientSource = nil
        identity = nil
        forgetLists()
        setConnection(connection)
    }

    private func setConnection(_ connection: Connection) {
        guard self.connection != connection else { return }
        self.connection = connection
        switch connection {
        case .notConnected(let account): UITiming.content(account == nil ? "prs not-connected" : "prs token-missing")
        case .noRemote(let host): UITiming.content("prs no-remote \(host)")
        case .resolving, .connected: break
        }
    }

    /// Another account or repository: nothing of the old one may show, and its answers still in flight are dropped.
    private func forgetLists() {
        refreshGeneration &+= 1
        if !lists.isEmpty { lists = [:] }
        if !checks.isEmpty { checks = [:] }
        if !branchPullRequests.isEmpty { branchPullRequests = [:] }
        settledChecks = []
        lastRefresh = nil
        pausedUntil = nil
        actionNotice = nil
    }

    /// `origin` when it names a repository on the host of one of `profile`'s accounts, else the first remote that
    /// does, with that repository and account. The account on the remote's host decides how its URL is read (its
    /// kind, and a GitLab account's base path).
    static func remote(
        in remotes: [RemoteInfo], profile: Profile
    ) -> (name: String, repository: HostedRepository, account: HostingAccount)? {
        let ordered = remotes.filter { $0.name == "origin" } + remotes.filter { $0.name != "origin" }
        return ordered.lazy
            .compactMap { remote in
                RemoteURL(remote.url).flatMap { profile.account(forHost: $0.host) }.flatMap { account in
                    account.kind.repository(fromRemoteURL: remote.url, basePath: account.basePath)
                        .map { (remote.name, $0, account) }
                }
            }
            .first
    }

    /// The client, the repository and its remote while connected: the PR detail loads and acts through them.
    var api: (client: any HostingProvider, repository: HostedRepository, remote: String)? {
        guard case .connected = connection, let client, let identity else { return nil }
        return (client, identity.repository, identity.remote)
    }

    /// Whether the connected provider offers `capability`; true while none is connected, as before providers had
    /// capabilities (an action then says the tab is not connected).
    func offers(_ capability: HostingCapabilities) -> Bool {
        api?.client.capabilities.contains(capability) ?? true
    }

    /// The connected provider's merge methods in the picker's order; all of them while none is connected.
    var mergeMethods: [HostedMergeMethod] {
        HostedMergeMethod.all.filter { api?.client.mergeMethods.contains($0) ?? true }
    }

    /// The web page of `target` in the connected repository; nil while not connected.
    func webURL(_ target: HostedWebTarget) -> URL? {
        guard let api else { return nil }
        return api.client.webURL(target, in: api.repository)
    }

    /// Reloads the lists now (after an action changed a pull request), unless a rate limit holds.
    func refreshNow() {
        guard case .connected = connection else { return }
        refreshTask?.cancel()
        refreshTask = Task { [weak self] in await self?.refresh() }
    }

    /// Reads `account`'s token of the profile `profileID` (the Keychain, off the main actor) and builds the client of
    /// the account's `kind`; nil without a usable token. The token stays inside the client.
    @concurrent
    private nonisolated static func makeClient(
        profileID: UUID, account: HostingAccount
    ) async -> (any HostingProvider)? {
        guard let token = await HostingTokens.token(for: account, profileID: profileID) else { return nil }
        return try? client(for: account, profileID: profileID, token: token)
    }

    /// The client of `account`'s `kind`, given its token just read: GitHub keeps `token`; GitLab asks
    /// `HostingTokens.accessToken` on each request (off the main actor; an OAuth sign-in through the refresher, else
    /// cached, read again after a 401), so a token saved again in Settings or renewed is used at once. A sign-in that
    /// cannot be renewed reads as a refused token, so every list and the detail offer Reconnect. Throws `HostingError`
    /// for a bad host or token.
    nonisolated static func client(
        for account: HostingAccount, profileID: UUID, token: String
    ) throws -> any HostingProvider {
        switch account.kind {
        case .github:
            return try GitHubClient(host: account.host, token: token)
        case .gitlab:
            return try GitLabClient(host: account.host, basePath: account.basePath) { rejected in
                do {
                    guard let token = try await HostingTokens.accessToken(
                        for: account, profileID: profileID, rejecting: rejected)
                    else { throw HostingError.unauthorized }
                    return token
                } catch OAuthRefresher.RefresherError.reconnectNeeded {
                    throw HostingError.unauthorized
                } catch OAuthRefresher.RefresherError.refreshFailed(let error) {
                    throw error
                }
            }
        }
    }

    // MARK: Loading

    /// Reloads the lists the sidebar shows (`SidebarSections`; rows already shown stay until the new ones are in),
    /// then the checks of their pull requests. Skipped while a rate limit holds.
    private func refresh() async {
        guard case .connected(let repository) = connection, let client, let remote = identity?.remote else { return }
        if let pausedUntil, pausedUntil > .now { return }
        refreshGeneration &+= 1
        let generation = refreshGeneration
        var shown = Set(SidebarSections.current.pullRequestLists)
        // A provider without issues reads no Issues list (the PRs tab leaves its card out too).
        if !client.capabilities.contains(.issues) { shown.remove(.assigned) }
        let (results, heads) = await Self.fetchLists(client, repository, remote: remote, shown: shown)
        guard generation == refreshGeneration, !Task.isCancelled else { return }
        // A failed All open keeps the badges it last gave.
        if let heads, heads != branchPullRequests { branchPullRequests = heads }
        var lists = self.lists
        // A hidden list keeps no rows or error: shown again, it starts on its skeleton and loads.
        for list in List.allCases where list != .allOpen && !shown.contains(list) { lists[list] = nil }
        for (list, result) in results {
            switch result {
            case .success(let rows):
                lists[list] = ListState(rows: rows, error: nil)
            case .failure(let error):
                lists[list, default: ListState()].error = listError(error)
            }
        }
        if lists != self.lists { self.lists = lists }
        // `content prs stub/stub mine:1 reviewRequested:0 allOpen:1 assigned:1` (`error` for a failed list).
        UITiming.content("prs \(repository.fullName) " + List.allCases.map { list in
            let state = lists[list]
            return "\(list.rawValue):" + (state?.error != nil ? "error" : "\(state?.rows?.count ?? 0)")
        }.joined(separator: " "))
        await refreshChecks(client, repository, generation: generation)
        // Only a refresh that ran to its end counts: one cut short (the PRs tab showing restarts `watch`) runs again.
        if generation == refreshGeneration, !Task.isCancelled { lastRefresh = .now }
    }

    private func refreshChecks(_ client: any HostingProvider, _ repository: HostedRepository, generation: Int) async {
        var commits: [String] = []
        let rows = [List.mine, .reviewRequested, .allOpen].flatMap { lists[$0]?.rows ?? [] }
        for sha in rows.compactMap(\.headSHA) where !commits.contains(sha) && !settledChecks.contains(sha) {
            commits.append(sha)
            if commits.count == Self.maxCheckedCommits { break }
        }
        guard !commits.isEmpty else { return }
        let results = await Self.fetchChecks(client, repository, commits: commits)
        guard generation == refreshGeneration, !Task.isCancelled else { return }
        var checks = self.checks
        for (sha, result) in results {
            switch result {
            case .success(let state):
                checks[sha] = state
                if state == .success { settledChecks.insert(sha) }
            case .failure(let error):
                // A token without the checks permission reads lists but not check runs: the rows show no state. A
                // rate limit still pauses the refreshes (`listError`).
                _ = listError(error)
                Self.logger.notice("check runs unreadable: \(String(describing: error), privacy: .public)")
            }
        }
        if checks != self.checks { self.checks = checks }
        // `content prs checks 1/1 success:1 failure:0 pending:0`: commits read, then their states.
        UITiming.content("prs checks \(results.count)/\(commits.count) " + [ChecksState.success, .failure, .pending]
            .map { state in "\(state):\(commits.count { checks[$0] == state })" }.joined(separator: " "))
    }

    /// The error's text in the words of this tab's host ("GitLab", "merge request").
    private func hostText(_ error: HostingError) -> String {
        error.description(host: kind.name, pullRequest: kind.pullRequestNoun.lowercased())
    }

    /// The card's text for a failed read; a rate limit also pauses the refreshes until it ends.
    private func listError(_ error: any Error) -> ListError {
        switch error {
        case HostingError.unauthorized:
            let host = identity?.account?.providerName ?? "GitHub"
            return ListError(message: "\(host) refused the token (revoked or expired).", reconnect: true)
        case HostingError.rateLimited(let resetsAt):
            pausedUntil = resetsAt ?? Date.now.addingTimeInterval(60)
            return ListError(message: "\(hostText(.rateLimited(resetsAt: resetsAt))) Histq tries again then.",
                             reconnect: false)
        case HostingError.secondaryRateLimited(let seconds):
            pausedUntil = Date.now.addingTimeInterval(TimeInterval(seconds ?? 60))
            return ListError(message: hostText(.secondaryRateLimited(retryAfterSeconds: seconds)), reconnect: false)
        case let error as HostingError:
            return ListError(message: hostText(error), reconnect: false)
        default:
            return ListError(message: error.localizedDescription, reconnect: false)
        }
    }

    /// The `shown` lists at once. My PRs and Review requested come from the search API (issue-shaped hits); the hits
    /// that All open has take its head commit (for the checks) and draft flag. All open is read even when hidden: the
    /// graph's badges by remote branch (`branchPullRequests`, nil when it failed) and the other lists need it.
    @concurrent
    private nonisolated static func fetchLists(
        _ client: any HostingProvider, _ repository: HostedRepository, remote: String, shown: Set<List>
    ) async -> (lists: [List: Result<[HostedRow], any Error>], heads: [String: RefBadge.PullRequest]?) {
        async let open = capture { try await client.pullRequests(in: repository, state: .open) }
        async let mine = capture(if: shown.contains(.mine)) { try await client.myOpenPullRequests(in: repository) }
        async let review = capture(if: shown.contains(.reviewRequested)) {
            try await client.reviewRequestedPullRequests(in: repository)
        }
        async let assigned = capture(if: shown.contains(.assigned)) {
            try await client.assignedOpenIssues(in: repository)
        }
        let (pulls, mineHits, reviewHits, issueHits) = await (open, mine, review, assigned)
        let byNumber = Dictionary(((try? pulls.get()) ?? []).map { ($0.number, $0) }, uniquingKeysWith: { a, _ in a })
        var lists: [List: Result<[HostedRow], any Error>] = [.allOpen: pulls.map { $0.map(HostedRow.init(pull:)) }]
        lists[.mine] = mineHits?.map { $0.map { HostedRow(searchHit: $0, pull: byNumber[$0.number]) } }
        lists[.reviewRequested] = reviewHits?.map { $0.map { HostedRow(searchHit: $0, pull: byNumber[$0.number]) } }
        lists[.assigned] = issueHits?.map {
            $0.filter { !$0.isPullRequest }.map { HostedRow(searchHit: $0, pull: nil) }
        }
        return (lists, (try? pulls.get()).map {
            branchPullRequests($0, repository: repository, remote: remote, numberPrefix: client.kind.numberPrefix)
        })
    }

    /// The badges of `pulls` by remote branch: only heads whose `owner:branch` label names the repository's owner (a
    /// fork's head is another repository's branch). When two pull requests share a head, the lowest number wins.
    /// `numberPrefix` goes before each chip's number (`!` on GitLab).
    nonisolated static func branchPullRequests(
        _ pulls: [HostedPullRequest], repository: HostedRepository, remote: String, numberPrefix: String
    ) -> [String: RefBadge.PullRequest] {
        var result: [String: RefBadge.PullRequest] = [:]
        for pull in pulls.sorted(by: { $0.number < $1.number }) where pull.state == "open" {
            guard let label = pull.head.label, let colon = label.firstIndex(of: ":"),
                  label[..<colon].lowercased() == repository.owner.lowercased()
            else { continue }
            let branch = "\(remote)/\(pull.head.ref)"
            if result[branch] == nil {
                result[branch] = RefBadge.PullRequest(
                    number: pull.number, isDraft: pull.draft ?? false, numberPrefix: numberPrefix)
            }
        }
        return result
    }

    /// The checks state of each commit (nil: no check runs).
    @concurrent
    private nonisolated static func fetchChecks(
        _ client: any HostingProvider, _ repository: HostedRepository, commits: [String]
    ) async -> [String: Result<ChecksState?, any Error>] {
        await withTaskGroup(of: (String, Result<ChecksState?, any Error>).self) { group in
            for sha in commits {
                group.addTask {
                    (sha, await capture { ChecksState(try await client.checkRuns(for: sha, in: repository)) })
                }
            }
            var results: [String: Result<ChecksState?, any Error>] = [:]
            for await (sha, result) in group { results[sha] = result }
            return results
        }
    }

    private nonisolated static func capture<T>(_ body: () async throws -> T) async -> Result<T, any Error> {
        do {
            return .success(try await body())
        } catch {
            return .failure(error)
        }
    }

    /// `capture`, or nil without a call when the list is not `wanted`.
    private nonisolated static func capture<T>(
        if wanted: Bool, _ body: () async throws -> T
    ) async -> Result<T, any Error>? {
        wanted ? await capture(body) : nil
    }
}
