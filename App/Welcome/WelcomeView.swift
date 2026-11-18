// A new tab's page: open a folder, clone a repository (streamed progress, cancel), init one, or reopen a recent one.
// When no usable git was found it explains why first, with a way to fix it without a relaunch.
import AppKit
import HistqCore
import SwiftUI

/// One Welcome tab's state, owned by `WindowModel` so a clone keeps running (and keeps its progress) while another
/// tab is shown. Every git call runs off the main actor; clone and init are user-initiated writes and use the write
/// environment. `open` opens a folder in this tab.
@Observable
@MainActor
final class WelcomeModel {
    /// Whether a usable git was found.
    enum GitCheck: Equatable {
        case checking
        case ok
        case problem(GitExecutableError)
    }

    enum CloneState: Equatable {
        case idle
        /// git's latest progress line, and its percentage when it has one.
        case running(line: String, fraction: Double?)
        case failed(String)
    }

    /// The page's three ways to get a repository; the options card selects one.
    enum Option: String, CaseIterable {
        case open, clone, initialize

        var title: String {
            switch self {
            case .open: "Open"
            case .clone: "Clone"
            case .initialize: "Init"
            }
        }

        var systemImage: String {
            switch self {
            case .open: "folder"
            case .clone: "arrow.down.circle"
            case .initialize: "plus.rectangle.on.folder"
            }
        }
    }

    /// Where the clone URL comes from: typed, or picked from the repositories of a profile's GitHub account (nil, or a
    /// profile no longer listed: the first one `gitHubProfiles` lists).
    enum CloneSource: Hashable {
        case url
        case github(profileID: UUID?)
    }

    /// A profile's GitHub repositories, for the clone picker.
    enum RepoList: Equatable {
        case idle
        case loading
        case loaded(account: Profile.GitHubAccount, repos: [GitHubRepository])
        /// No default profile or GitHub account on it, or (`account` set) its token is not in the Keychain.
        case notConnected(account: Profile.GitHubAccount?)
        /// `reconnect` when GitHub refused the token.
        case failed(message: String, reconnect: Bool)
    }

    private(set) var gitCheck = GitCheck.checking
    /// "Install Command Line Tools" was clicked: the card says to come back once the installer is done.
    private(set) var installStarted = false
    var cloneURL = ""
    /// The folder the clone goes into, as `<cloneParent>/<repoName>`.
    private(set) var cloneParent: URL
    private(set) var clone = CloneState.idle
    private(set) var initError: String?
    var option = Option.clone
    /// Switching to a GitHub source loads its repositories in the background (never blocks the switch).
    var cloneSource = CloneSource.url {
        didSet {
            sourceChosen = true
            if case .github = cloneSource { loadRepositoriesIfNeeded() }
        }
    }
    private(set) var repoList = RepoList.idle
    /// A refresh runs while the last loaded repositories stay listed.
    private(set) var isRefreshing = false
    /// The repository picked in the GitHub list; its URL is in `cloneURL`.
    private(set) var selectedRepoID: Int?

    @ObservationIgnored private let open: (URL) -> Void
    @ObservationIgnored private var checkTask: Task<Void, Never>?
    @ObservationIgnored private var cloneTask: Task<Void, Never>?
    /// Changes with every clone start or cancel, so a stale clone's progress or end is dropped.
    @ObservationIgnored private var cloneToken = 0
    /// The source was set (by the user, or once to GitHub for a connected account): the default no longer applies.
    @ObservationIgnored private var sourceChosen = false
    @ObservationIgnored private var reposTask: Task<Void, Never>?
    /// Changes with every repository load or cancel, so a stale answer is dropped.
    @ObservationIgnored private var reposToken = 0
    /// The profile whose repositories `repoList` holds (or is loading): the one a GitHub clone runs as.
    @ObservationIgnored private var repoProfileID: UUID?
    /// That profile's GitHub account when the list was asked for: another account on the same profile reloads.
    @ObservationIgnored private var repoAccount: Profile.GitHubAccount?

    init(open: @escaping (URL) -> Void) {
        self.open = open
        cloneParent = RecentRepos.shared.urls.first?.deletingLastPathComponent()
            ?? FileManager.default.homeDirectoryForCurrentUser
        #if DEBUG
        // QA: `-HistqWelcomeSource github` opens the Clone form on the GitHub list (with `-HistqGitHubStub YES`).
        if AppState.launchFlag("-HistqWelcomeSource") == "github" {
            cloneSource = .github(profileID: nil)
            loadRepositoriesIfNeeded()
        }
        #endif
        // A connected GitHub account makes GitHub the default source (the Keychain is read off the main actor, and
        // cached); not when the user has picked a source or typed a URL meanwhile.
        Task { [weak self] in
            guard await Self.isGitHubConnected(), let self, !sourceChosen, cloneURL.isEmpty else { return }
            cloneSource = .github(profileID: nil)
        }
    }

    deinit {
        // A window closing drops its Welcome models without `cancel()`: stop the clone (git with it).
        cloneTask?.cancel()
        checkTask?.cancel()
        reposTask?.cancel()
    }

    /// The folder name a clone of `cloneURL` gets: its last path component without `.git`.
    var repoName: String {
        var text = cloneURL.trimmingCharacters(in: .whitespacesAndNewlines)
        while text.hasSuffix("/") { text.removeLast() }
        let last = text.split(whereSeparator: { "/:\\".contains($0) }).last.map(String.init) ?? ""
        let name = last.hasSuffix(".git") ? String(last.dropLast(4)) : last
        return name == "." || name == ".." ? "" : name
    }

    var cloneDestination: URL? {
        repoName.isEmpty ? nil : cloneParent.appending(path: repoName, directoryHint: .isDirectory)
    }

    var isCloning: Bool {
        if case .running = clone { return true }
        return false
    }

    /// The picked repository while it is still listed and `cloneURL` is still its URL.
    var selectedRepository: GitHubRepository? {
        guard case .loaded(_, let repos) = repoList else { return nil }
        return repos.first { $0.id == selectedRepoID && $0.cloneURL == cloneURL }
    }

    /// A clone can start: a destination, and in GitHub mode a listed repository (never a hidden typed URL).
    var canClone: Bool {
        guard cloneDestination != nil else { return false }
        return cloneSource == .url || selectedRepository != nil
    }

    /// A git path is set in the preferences (not auto-detected).
    var hasGitOverride: Bool {
        !(Preferences.defaults.string(forKey: PrefKey.gitPath.rawValue) ?? "").isEmpty
    }

    // MARK: Git check

    /// Checks git once per model (the view calls it on appear).
    func checkGitIfNeeded() {
        guard checkTask == nil else { return }
        checkGit()
    }

    /// Forgets the resolved git and looks again: after "Choose git…" or a Command Line Tools install.
    func checkGitAgain() {
        GitToolchain.reset()
        checkGit()
    }

    private func checkGit() {
        checkTask?.cancel()
        gitCheck = .checking
        checkTask = Task { [weak self] in
            let result: GitCheck
            do {
                _ = try await GitToolchain.resolve()
                result = .ok
            } catch {
                result = .problem(error as? GitExecutableError ?? .notFound)
            }
            guard !Task.isCancelled, let self else { return }
            gitCheck = result
            if result == .ok { installStarted = false }
        }
    }

    /// Asks macOS to install the Command Line Tools (`xcode-select --install` shows the system installer).
    func installCommandLineTools() {
        installStarted = true
        Task.detached(priority: .userInitiated) {
            let process = Process()
            process.executableURL = URL(filePath: "/usr/bin/xcode-select")
            process.arguments = ["--install"]
            process.standardInput = FileHandle.nullDevice
            process.standardOutput = FileHandle.nullDevice
            process.standardError = FileHandle.nullDevice
            guard (try? process.run()) != nil else { return }
            process.waitUntilExit()
        }
    }

    /// Lets the user pick a git binary, saves it as the `gitPath` preference, and checks again.
    func chooseGit() {
        let panel = NSOpenPanel()
        panel.canChooseFiles = true
        panel.canChooseDirectories = false
        panel.allowsMultipleSelection = false
        panel.showsHiddenFiles = true
        panel.treatsFilePackagesAsDirectories = true
        panel.prompt = "Use This Git"
        panel.message = "Choose a git executable (2.36 or later)"
        Task { @MainActor in
            guard await panel.begin() == .OK, let url = panel.url else { return }
            Preferences.defaults.set(url.path, forKey: PrefKey.gitPath.rawValue)
            self.checkGitAgain()
        }
    }

    /// Clears the `gitPath` preference: git is auto-detected again.
    func useAutomaticGit() {
        Preferences.defaults.set("", forKey: PrefKey.gitPath.rawValue)
        checkGitAgain()
    }

    // MARK: Open and init

    /// Picks a folder and opens it in this tab.
    func chooseFolderToOpen() {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.allowsMultipleSelection = false
        panel.prompt = "Open"
        panel.message = "Choose a repository"
        Task { @MainActor in
            guard await panel.begin() == .OK, let url = panel.url else { return }
            self.open(url)
        }
    }

    /// Opens a recent repository in this tab.
    func openRecent(_ url: URL) {
        open(url)
    }

    /// Picks (or creates) a folder, runs `git init` in it, and opens it in this tab.
    func chooseFolderToInit() {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.canCreateDirectories = true
        panel.allowsMultipleSelection = false
        panel.prompt = "Create Repository"
        panel.message = "Choose the folder for the new repository"
        Task { @MainActor in
            guard await panel.begin() == .OK, let url = panel.url else { return }
            self.initError = nil
            do {
                try await Self.initRepository(at: url)
                self.open(url)
            } catch {
                self.initError = Self.message(for: error)
            }
        }
    }

    @concurrent
    private nonisolated static func initRepository(at url: URL) async throws {
        let toolchain = try await GitToolchain.resolve()
        let runner = GitRunner(executable: toolchain.executable.url)
        let writeEnv = GitInvocation.environment(profile: nil, base: await GitToolchain.writeBase(), access: .write)
        try await GitOperations.initRepository(at: url, runner: runner, env: writeEnv)
    }

    // MARK: Clone

    /// Picks the folder the clone goes into.
    func chooseCloneParent() {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.canCreateDirectories = true
        panel.allowsMultipleSelection = false
        panel.directoryURL = cloneParent
        panel.prompt = "Choose"
        panel.message = "Choose where to put the clone"
        Task { @MainActor in
            guard await panel.begin() == .OK, let url = panel.url else { return }
            self.cloneParent = url
        }
    }

    /// Clones `cloneURL` into `cloneDestination`, streaming git's progress; opens the clone in this tab when done.
    func startClone() {
        guard !isCloning, canClone, let destination = cloneDestination else { return }
        let url = cloneURL.trimmingCharacters(in: .whitespacesAndNewlines)
        // A repository from a profile's GitHub list clones as that profile; a typed URL as the default profile.
        let profileID = cloneSource == .url ? nil : repoProfileID
        cloneToken &+= 1
        let token = cloneToken
        clone = .running(line: "Starting…", fraction: nil)
        // Called off the main actor for each of git's progress lines.
        let report: @Sendable (String) -> Void = { [weak self] line in
            Task { @MainActor in self?.progress(line, token: token) }
        }
        cloneTask = Task { [weak self] in
            do {
                try await Self.clone(url, into: destination, profileID: profileID, progress: report)
                guard let self, token == cloneToken else { return }
                clone = .idle
                cloneURL = ""
                // Before the tab opens, so its session resolves the repo to the profile it was cloned as.
                if let profileID { ProfileLibrary.shared.update { $0.remember(profileID, forRepo: destination) } }
                open(destination)
            } catch {
                guard let self, token == cloneToken else { return }
                clone = error is CancellationError || Task.isCancelled ? .idle : .failed(Self.message(for: error))
            }
        }
    }

    /// Stops the clone in flight (git removes its unfinished folder): the Cancel button.
    func cancelClone() {
        cloneTask?.cancel()
        cloneTask = nil
        cloneToken &+= 1
        if isCloning { clone = .idle }
    }

    /// Stops everything in flight: the tab closed.
    func cancel() {
        cancelClone()
        checkTask?.cancel()
        reposTask?.cancel()
        reposTask = nil
        reposToken &+= 1
        isRefreshing = false
    }

    private func progress(_ line: String, token: Int) {
        guard token == cloneToken, isCloning else { return }
        let text = line.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { return }
        let percent = text.firstMatch(of: /(\d{1,3})%/).flatMap { Double($0.1) }
        clone = .running(line: text, fraction: percent.map { min($0, 100) / 100 })
    }

    @concurrent
    private nonisolated static func clone(
        _ url: String, into destination: URL, profileID: UUID?,
        progress: @escaping @Sendable (String) -> Void
    ) async throws {
        let toolchain = try await GitToolchain.resolve()
        let runner = GitRunner(executable: toolchain.executable.url)
        // The clone opens with `profileID`'s profile (the default one when nil or deleted), so it clones as that
        // profile too (SSH key) and, when the URL (after the user's rewrites) is https on the profile's GitHub host,
        // with its token.
        let store = await ProfileLibrary.shared.loaded()
        let profile = profileID.flatMap { store?.profile(id: $0) } ?? store?.defaultProfile
        let token = await GitHubTokens.token(for: profile)
        let cloneEnv = await GitInvocation.cloneEnvironment(
            url: url, profile: profile, base: await GitToolchain.writeBase(), token: token, runner: runner)
        try await GitOperations.clone(url: url, into: destination, runner: runner, env: cloneEnv, progress: progress)
    }

    // MARK: GitHub repositories

    /// The loaded repositories grouped by owner: the account's own login first, then the others alphabetically.
    var repoGroups: [(owner: String, repos: [GitHubRepository])] {
        guard case .loaded(let account, let repos) = repoList else { return [] }
        let groups = Dictionary(grouping: repos, by: \.owner.login)
        let owners = groups.keys.sorted { lhs, rhs in
            let lhsOwn = lhs.caseInsensitiveCompare(account.login) == .orderedSame
            if lhsOwn != (rhs.caseInsensitiveCompare(account.login) == .orderedSame) { return lhsOwn }
            return lhs.localizedCaseInsensitiveCompare(rhs) == .orderedAscending
        }
        return owners.map { (owner: $0, repos: groups[$0] ?? []) }
    }

    /// The profiles with a GitHub account, the default profile first: the Source picker's GitHub entries.
    nonisolated static func gitHubProfiles(in store: ProfileStore) -> [Profile] {
        let profiles = store.profiles.filter { $0.github != nil }
        let defaultID = store.defaultProfileID
        return profiles.filter { $0.id == defaultID } + profiles.filter { $0.id != defaultID }
    }

    /// The GitHub profile `id` names while it is listed, else the first listed one.
    nonisolated static func gitHubProfile(_ id: UUID?, in store: ProfileStore) -> Profile? {
        let profiles = gitHubProfiles(in: store)
        return profiles.first { $0.id == id } ?? profiles.first
    }

    /// The profile the GitHub source lists; nil for the URL source, with no GitHub profile, or before the profiles
    /// are read.
    var gitHubProfile: Profile? {
        guard case .github(let id) = cloneSource, let store = ProfileLibrary.shared.store else { return nil }
        return Self.gitHubProfile(id, in: store)
    }

    /// Loads the repositories unless they are loading or loaded already. Another profile picked, or the profile's
    /// account changed or went (once the profiles are read): its list replaces the shown one (the placeholder in the
    /// same frame), and the pick from the shown one goes.
    func loadRepositoriesIfNeeded() {
        let profile = gitHubProfile
        if ProfileLibrary.shared.store != nil, profile?.id != repoProfileID || profile?.github != repoAccount {
            if selectedRepository != nil { cloneURL = "" }
            selectedRepoID = nil
            isRefreshing = false
            repoList = .idle
            return loadRepositories()
        }
        switch repoList {
        case .idle, .notConnected, .failed(_, reconnect: true): loadRepositories()
        case .loading, .loaded, .failed: break
        }
    }

    /// Loads the repositories again: the refresh button.
    func refreshRepositories() {
        loadRepositories()
    }

    /// Clones `repo` next: its URL goes into `cloneURL`, so the destination and the clone work as for a typed URL.
    func selectRepository(_ repo: GitHubRepository) {
        cloneURL = repo.cloneURL
        selectedRepoID = repo.id
    }

    private func loadRepositories() {
        reposTask?.cancel()
        reposToken &+= 1
        let token = reposToken
        let requested: UUID? = if case .github(let id) = cloneSource { id } else { nil }
        // nil before the profiles are read: the answer says which profile it listed.
        repoProfileID = gitHubProfile?.id
        repoAccount = gitHubProfile?.github
        if case .loaded = repoList { isRefreshing = true } else { repoList = .loading }
        reposTask = Task { [weak self] in
            let (profile, result) = await Self.fetchRepositories(requested)
            guard !Task.isCancelled, let self, token == reposToken else { return }
            isRefreshing = false
            repoProfileID = profile?.id
            repoAccount = profile?.github
            repoList = result
            switch result {
            case .loaded(_, let repos): UITiming.content("welcome repos \(repos.count)")
            case .notConnected: UITiming.content("welcome repos not-connected")
            default: UITiming.content("welcome repos error")
            }
        }
    }

    /// The repositories of the GitHub profile `id` resolves to (`gitHubProfile(_:in:)`), with that profile, read off
    /// the main actor; the token stays inside the client.
    @concurrent
    private nonisolated static func fetchRepositories(_ id: UUID?) async -> (Profile?, RepoList) {
        let profile = await ProfileLibrary.shared.loaded().flatMap { gitHubProfile(id, in: $0) }
        #if DEBUG
        if GitHubStub.isEnabled {
            // No Keychain, no network: the stub session answers, for any profile.
            let account = profile?.github ?? Profile.GitHubAccount(host: "github.com", login: "stub")
            return (profile, await repoList(account, client: GitHubStub.client))
        }
        #endif
        guard let profile, let account = profile.github else { return (nil, .notConnected(account: nil)) }
        guard let token = await GitHubTokens.token(for: profile) else {
            return (profile, .notConnected(account: account))
        }
        return (profile, await repoList(account) { try GitHubClient(host: account.host, token: token) })
    }

    /// The first GitHub profile (the default one when it has an account) has its token in the Keychain (always under
    /// the DEBUG stub).
    @concurrent
    private nonisolated static func isGitHubConnected() async -> Bool {
        #if DEBUG
        if GitHubStub.isEnabled { return true }
        #endif
        guard let store = await ProfileLibrary.shared.loaded(), let profile = gitHubProfile(nil, in: store) else {
            return false
        }
        return await GitHubTokens.token(for: profile) != nil
    }

    @concurrent
    private nonisolated static func repoList(
        _ account: Profile.GitHubAccount, client makeClient: () throws -> GitHubClient?
    ) async -> RepoList {
        do {
            guard let client = try makeClient() else { return .failed(message: "No GitHub client.", reconnect: false) }
            return .loaded(account: account, repos: try await client.userRepositories())
        } catch {
            return repoListError(error)
        }
    }

    private nonisolated static func repoListError(_ error: any Error) -> RepoList {
        switch error {
        case GitHubError.unauthorized:
            .failed(message: "GitHub refused the token (revoked or expired). Reconnect the account in Settings › "
                + "Integrations.", reconnect: true)
        case let error as GitHubError:
            .failed(message: String(describing: error), reconnect: false)
        default:
            .failed(message: error.localizedDescription, reconnect: false)
        }
    }

    /// A short message for a failed clone or init: git's last error line.
    private nonisolated static func message(for error: Error) -> String {
        switch error {
        case let error as GitError:
            let lines = error.stderrTail.split(whereSeparator: \.isNewline).map(String.init)
            return lines.last { $0.hasPrefix("fatal:") || $0.hasPrefix("error:") } ?? lines.last ?? "git failed."
        case GitOperationError.invalidRemoteURL:
            return "Enter a repository URL or path."
        case is GitExecutableError:
            return "No usable git was found."
        default:
            return error.localizedDescription
        }
    }
}

/// Sizes of the Welcome page.
private enum WelcomeMetrics {
    /// The three panels together; a wider window centers them.
    static let maxWidth: CGFloat = 1200
}

/// The page of a tab with no repository: three panels of cards on the page's sheet, as a repo tab's. The options
/// (Open, Clone, Init), the selected option's form, and the recent repositories.
struct WelcomeView: View {
    let model: WelcomeModel

    var body: some View {
        HStack(spacing: RepoLayoutMetrics.gap) {
            OptionsCard(model: model)
                .frame(width: RepoLayoutMetrics.sidebar.lowerBound)
            ScrollView {
                VStack(alignment: .leading, spacing: SectionCardMetrics.spacing) {
                    if case .problem(let error) = model.gitCheck {
                        GitProblemCard(model: model, error: error)
                    }
                    switch model.option {
                    case .open: OpenCard(model: model)
                    case .clone: CloneCard(model: model)
                    case .initialize: InitCard(model: model)
                    }
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            RecentCard(model: model)
                .frame(width: RepoLayoutMetrics.detail.lowerBound)
        }
        .frame(maxWidth: WelcomeMetrics.maxWidth, maxHeight: .infinity)
        .padding(RepoLayoutMetrics.inset)
        // Centered on a wide window: the form's labels and controls never drift far apart.
        .frame(maxWidth: .infinity)
        .labeledContentStyle(.settingsRow)
        .onAppear { model.checkGitIfNeeded() }
    }
}

/// The page's options as sidebar rows: a click shows the option's form at once. Up/Down move the selection while the
/// card has the focus.
private struct OptionsCard: View {
    let model: WelcomeModel

    var body: some View {
        SectionCard("Welcome", systemImage: "sparkles", contentPadding: 6) {
            VStack(alignment: .leading, spacing: SidebarItemStyle.spacing) {
                ForEach(WelcomeModel.Option.allCases, id: \.self) { option in
                    Button { select(option) } label: {
                        Label(option.title, systemImage: option.systemImage)
                    }
                    .buttonStyle(SidebarItemStyle(selected: option == model.option))
                    .accessibilityAddTraits(option == model.option ? .isSelected : [])
                }
                Spacer(minLength: 0)
            }
            .frame(maxHeight: .infinity)
        }
        .frame(maxHeight: .infinity)
        .focusable()
        .focusEffectDisabled()
        .onMoveCommand(perform: move)
    }

    private func select(_ option: WelcomeModel.Option) {
        guard option != model.option else { return }
        UITiming.select("welcome \(option.rawValue)")
        model.option = option
    }

    /// Up/Down: the previous or next option, stopping at the ends.
    private func move(_ direction: MoveCommandDirection) {
        let all = WelcomeModel.Option.allCases
        guard let index = all.firstIndex(of: model.option) else { return }
        switch direction {
        case .up where index > all.startIndex: select(all[index - 1])
        case .down where index < all.count - 1: select(all[index + 1])
        default: break
        }
    }
}

/// Why git cannot run, and the ways out: install the Command Line Tools, choose a git, check again.
private struct GitProblemCard: View {
    let model: WelcomeModel
    let error: GitExecutableError

    var body: some View {
        SectionCard(title, systemImage: "exclamationmark.triangle.fill") {
            VStack(alignment: .leading, spacing: 8) {
                Text(explanation)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                if model.installStarted {
                    Text("When the installer has finished, click Check Again.")
                        .font(.settingsCaption)
                        .foregroundStyle(.secondary)
                }
                HStack(spacing: 8) {
                    if offersInstall {
                        Button("Install Command Line Tools") { model.installCommandLineTools() }
                            .buttonStyle(RowTextButtonStyle(prominent: true))
                    }
                    Button("Choose git…") { model.chooseGit() }
                        .buttonStyle(RowTextButtonStyle())
                    if model.hasGitOverride {
                        Button("Detect Automatically") { model.useAutomaticGit() }
                            .buttonStyle(RowTextButtonStyle())
                    }
                    Button("Check Again") { model.checkGitAgain() }
                        .buttonStyle(RowTextButtonStyle())
                }
            }
        }
    }

    /// The Command Line Tools bring a recent git.
    private var offersInstall: Bool {
        switch error {
        case .commandLineToolsMissing, .tooOld, .notFound: true
        case .notExecutable, .unrecognizedVersion: false
        }
    }

    private var title: String {
        switch error {
        case .commandLineToolsMissing: "Git needs the Command Line Tools"
        case .tooOld(let version): "Git \(version) is too old"
        case .notFound: "Git was not found"
        case .notExecutable: "The chosen git cannot run"
        case .unrecognizedVersion: "Git did not report its version"
        }
    }

    private var explanation: String {
        switch error {
        case .commandLineToolsMissing:
            "macOS provides git with Apple's Command Line Tools, which are not installed. Install them, or choose "
                + "another git."
        case .tooOld:
            "Histq needs git \(GitExecutable.minimumVersion) or later. Install the Command Line Tools or a newer "
                + "git (for example with Homebrew), or choose one."
        case .notFound:
            "No git was found on your PATH. Install the Command Line Tools, or choose a git."
        case .notExecutable(let path):
            "\(path) is not an executable git. Choose another one, or let Histq detect git automatically."
        case .unrecognizedVersion(let output):
            "Running git --version printed \"\(output)\". Choose another git."
        }
    }
}

/// Opens a folder in this tab.
private struct OpenCard: View {
    let model: WelcomeModel

    var body: some View {
        SectionCard("Open", systemImage: "folder") {
            LabeledContent {
                Button("Open…") { model.chooseFolderToOpen() }
                    .buttonStyle(RowTextButtonStyle(formRow: true))
            } label: {
                Text("Open a repository")
                Text("A folder with a git repository on this Mac.")
                    .font(.settingsCaption)
                    .foregroundStyle(.secondary)
            }
        }
    }
}

/// Creates a repository with `git init` and opens it in this tab.
private struct InitCard: View {
    let model: WelcomeModel

    var body: some View {
        SectionCard("Init", systemImage: "plus.rectangle.on.folder") {
            LabeledContent {
                Button("Init…") { model.chooseFolderToInit() }
                    .buttonStyle(RowTextButtonStyle(formRow: true))
                    .disabled(isGitMissing)
            } label: {
                Text("Create a repository")
                Text(model.initError ?? "Runs git init in a folder you choose.")
                    .font(.settingsCaption)
                    .foregroundStyle(model.initError == nil ? Color.secondary : Color.red)
            }
        }
    }

    private var isGitMissing: Bool {
        if case .problem = model.gitCheck { return true }
        return false
    }
}

/// The clone form: the source (a typed URL, or the connected GitHub account's repositories), destination, then the
/// Clone button, or git's progress with Cancel while it runs.
private struct CloneCard: View {
    @Bindable var model: WelcomeModel
    @Environment(WindowModel.self) private var windowModel

    var body: some View {
        SectionCard("Clone", systemImage: "arrow.down.circle") {
            LabeledContent {
                CapsuleMenuPicker(label: "Source", selection: source, title: Text(sourceTitle(source.wrappedValue))) {
                    Text(sourceTitle(.url)).tag(WelcomeModel.CloneSource.url)
                    ForEach(gitHubSources, id: \.self) { source in
                        Text(sourceTitle(source)).tag(source)
                    }
                }
                .disabled(model.isCloning)
            } label: {
                Text("Source")
            }
            SettingsDivider()
            switch model.cloneSource {
            case .url:
                LabeledContent {
                    TextField("Repository URL", text: $model.cloneURL, prompt: Text(verbatim: "https://github.com/owner/repo.git"))
                        .textFieldStyle(.settings)
                        .labelsHidden()
                        .frame(maxWidth: 300)
                        .disabled(model.isCloning)
                        .onSubmit(model.startClone)
                } label: {
                    Text("URL")
                }
            case .github:
                // Its own view, so git's progress lines (which redraw this card) never rebuild the repository menu.
                RepositoryRow(model: model)
                    .disabled(model.isCloning)
            }
            SettingsDivider()
            LabeledContent {
                Button("Choose…") { model.chooseCloneParent() }
                    .buttonStyle(RowTextButtonStyle(formRow: true))
                    .disabled(model.isCloning)
            } label: {
                Text("Destination")
                Text(model.cloneDestination?.path ?? model.cloneParent.path)
                    .font(.settingsCaption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .truncationMode(.middle)
            }
            SettingsDivider()
            status
        }
        .onChange(of: windowModel.isSettingsOpen) { _, open in
            // Back from Settings › Integrations: a list that was not connected or refused loads again.
            if !open, model.cloneSource != .url { model.loadRepositoriesIfNeeded() }
        }
        .onChange(of: model.gitHubProfile, initial: true) {
            // The profile the source resolves to, or its account, changed (a Settings edit, another window, or while
            // this card was hidden): the list follows it, so the title, the list and the clone's profile match.
            if model.cloneSource != .url { model.loadRepositoriesIfNeeded() }
        }
    }

    /// The Source picker's GitHub entries: one per profile with a GitHub account, the default first; a lone "GitHub"
    /// (which says to connect an account) when there is none.
    private var gitHubSources: [WelcomeModel.CloneSource] {
        let profiles = ProfileLibrary.shared.store.map(WelcomeModel.gitHubProfiles(in:)) ?? []
        return profiles.isEmpty ? [.github(profileID: nil)] : profiles.map { .github(profileID: $0.id) }
    }

    /// The Source picker's selection, a GitHub source as the entry it resolves to; a switch logs its select line
    /// (switching to another GitHub profile shows the list's placeholder in the same frame).
    private var source: Binding<WelcomeModel.CloneSource> {
        Binding(get: {
            model.cloneSource == .url ? .url : .github(profileID: model.gitHubProfile?.id)
        }, set: { new in
            guard new != source.wrappedValue else { return }
            UITiming.select("welcome source \(new == .url ? "url" : "github")")
            model.cloneSource = new
        })
    }

    /// "URL", or "GitHub · login (profile)" for the profile a GitHub source resolves to ("GitHub" without one).
    private func sourceTitle(_ source: WelcomeModel.CloneSource) -> String {
        guard case .github(let id) = source else { return "URL" }
        guard let store = ProfileLibrary.shared.store, let profile = WelcomeModel.gitHubProfile(id, in: store),
              let account = profile.github
        else { return "GitHub" }
        return "GitHub · \(account.login) (\(ProfilePicker.title(profile)))"
    }

    @ViewBuilder
    private var status: some View {
        switch model.clone {
        case .running(let line, let fraction):
            HStack(spacing: 12) {
                VStack(alignment: .leading, spacing: 4) {
                    if let fraction {
                        ProgressView(value: fraction)
                    } else {
                        ProgressView().progressViewStyle(.linear)
                    }
                    Text(line)
                        .font(.settingsCaption)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                        .truncationMode(.tail)
                }
                Button("Cancel") { model.cancelClone() }
                    .buttonStyle(RowTextButtonStyle(formRow: true))
            }
        case .idle, .failed:
            HStack(spacing: 12) {
                if case .failed(let message) = model.clone {
                    Label(message, systemImage: "exclamationmark.triangle")
                        .font(.settingsCaption)
                        .foregroundStyle(.red)
                        .lineLimit(3)
                        .fixedSize(horizontal: false, vertical: true)
                }
                Spacer(minLength: 0)
                Button("Clone") { model.startClone() }
                    .buttonStyle(RowTextButtonStyle(formRow: true, prominent: true))
                    .disabled(!model.canClone || isGitMissing)
            }
        }
    }

    private var isGitMissing: Bool {
        if case .problem = model.gitCheck { return true }
        return false
    }
}

/// The connected GitHub account's repositories, grouped by owner in a dropdown, with a refresh button; a capsule
/// skeleton while they load, or why they cannot be listed with a way to Settings › Integrations.
private struct RepositoryRow: View {
    let model: WelcomeModel
    @Environment(WindowModel.self) private var windowModel

    var body: some View {
        switch model.repoList {
        case .idle, .loading:
            LabeledContent {
                HStack(spacing: 8) {
                    SkeletonLine(width: 200, height: 12)
                    DelayedSpinner(detail: "welcome repos")
                        .frame(width: 24, height: 24)
                }
                .frame(minHeight: 24)
                .accessibilityElement(children: .ignore)
                .accessibilityLabel("Loading")
                .onAppear { UITiming.placeholder("welcome repos") }
            } label: {
                Text("Repository")
            }
        case .loaded(_, let repos):
            RepositoryPicker(model: model, repos: repos)
        case .notConnected(let account):
            LabeledContent {
                settingsButton
            } label: {
                Text("Repository")
                Text(account.map { "The token for \($0.login) is missing. Reconnect in Settings › Integrations." }
                    ?? "Connect a GitHub account in Settings › Integrations.")
                    .font(.settingsCaption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        case .failed(let message, let reconnect):
            LabeledContent {
                HStack(spacing: 8) {
                    Button("Try Again") { model.refreshRepositories() }
                        .buttonStyle(RowTextButtonStyle(formRow: true))
                    if reconnect { settingsButton }
                }
            } label: {
                Text("Repository")
                Text(message)
                    .font(.settingsCaption)
                    .foregroundStyle(.red)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }

    private var settingsButton: some View {
        Button("Open Settings") { windowModel.selectSettings(.integrations) }
            .buttonStyle(RowTextButtonStyle(formRow: true))
    }
}

/// The GitHub repositories as a search field: typing fuzzy-filters them (`FuzzyRank` on the
/// name and `owner/name`, off the main actor) in a list under the field, grouped by owner. Up/Down move the highlight,
/// Return picks it, Escape closes the list, the chevron opens or closes it. A pick fills the field with `owner/name`;
/// that text lists every repository again.
private struct RepositoryPicker: View {
    typealias Groups = [(owner: String, repos: [GitHubRepository])]

    let model: WelcomeModel
    let repos: [GitHubRepository]
    @State private var query = ""
    @State private var isOpen = false
    /// The groups the list shows: `repos` filtered by the query.
    @State private var shown: Groups = []
    @State private var highlighted: Int?
    @FocusState private var focused: Bool

    /// What the list is filtered for: changes rerun the filter.
    private struct FilterKey: Equatable {
        let query: String
        let repos: [GitHubRepository]
    }

    /// The query the list is filtered by: none while the field shows the picked repository.
    private var filterQuery: String {
        query == model.selectedRepository?.fullName ? "" : query
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            LabeledContent {
                HStack(spacing: 8) {
                    field
                    refreshButton
                }
            } label: {
                Text("Repository")
                Text(repos.count == 1 ? "1 repository" : "\(repos.count) repositories")
                    .font(.settingsCaption)
                    .foregroundStyle(.secondary)
                Text("Organization repositories appear when the organization allows Histq's GitHub access.")
                    .font(.settingsCaption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            if isOpen { list }
        }
        .onAppear {
            query = model.selectedRepository?.fullName ?? ""
            #if DEBUG
            // QA: `-HistqWelcomeRepoQuery <text>` opens the list filtered for it (with `-HistqWelcomeSource github`).
            if let text = AppState.launchFlag("-HistqWelcomeRepoQuery") {
                query = text
                isOpen = true
            }
            #endif
        }
        .task(id: FilterKey(query: filterQuery, repos: repos)) {
            let query = filterQuery
            let result = await Self.filter(model.repoGroups, query: query)
            guard !Task.isCancelled else { return }
            shown = result
            let ids = result.flatMap { $0.repos.map(\.id) }
            if highlighted.map({ !ids.contains($0) }) ?? true {
                let selected = model.selectedRepository?.id
                highlighted = selected.flatMap { ids.contains($0) ? $0 : nil } ?? ids.first
            }
            if !query.isEmpty { UITiming.content("welcome repos filter \(ids.count)") }
        }
    }

    /// The field with a search icon and the chevron, in the card's input look.
    private var field: some View {
        HStack(spacing: 6) {
            Image(systemName: "magnifyingglass")
                .font(.system(size: 11))
                .foregroundStyle(.secondary)
            TextField("Repository", text: $query, prompt: Text("Search repositories"))
                .textFieldStyle(.plain)
                .labelsHidden()
                .focused($focused)
                .onSubmit(pickHighlighted)
                .onKeyPress(.downArrow) { move(by: 1) }
                .onKeyPress(.upArrow) { move(by: -1) }
                .onKeyPress(.escape) {
                    guard isOpen else { return .ignored }
                    isOpen = false
                    return .handled
                }
            Button {
                isOpen.toggle()
                if isOpen { focused = true }
            } label: {
                Image(systemName: "chevron.down")
                    .font(.system(size: 10, weight: .semibold))
                    .rotationEffect(.degrees(isOpen ? 180 : 0))
                    .frame(width: 18, height: 18)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .foregroundStyle(.secondary)
            .accessibilityLabel(isOpen ? "Hide the repositories" : "Show the repositories")
        }
        .padding(.leading, 10)
        .padding(.trailing, 6)
        .frame(minHeight: SettingsInputMetrics.minHeight)
        .modifier(SettingsInputChrome(focused: focused))
        .frame(maxWidth: 360)
        .onChange(of: focused) { _, focused in
            if focused { isOpen = true }
        }
        .onChange(of: query) { _, query in
            // Typing opens the list; the text a pick wrote does not.
            if focused, query != model.selectedRepository?.fullName { isOpen = true }
        }
    }

    /// The filtered repositories under the field, grouped by owner, at most `maxHeight` tall.
    private var list: some View {
        let rows = shown.reduce(0) { $0 + $1.repos.count }
        let height = min(Self.maxHeight, CGFloat(rows) * (SidebarItemStyle.height + 2) + CGFloat(shown.count) * 26 + 12)
        return ScrollViewReader { proxy in
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 2) {
                    ForEach(shown, id: \.owner) { group in
                        Text(group.owner.uppercased())
                            .font(.settingsCaption)
                            .foregroundStyle(.secondary)
                            .padding(.horizontal, 10)
                            .padding(.top, 6)
                            .padding(.bottom, 2)
                        ForEach(group.repos) { repo in
                            Button { pick(repo) } label: {
                                Label(repo.name, systemImage: repo.isPrivate ? "lock" : "book.closed")
                            }
                            .buttonStyle(SidebarItemStyle(selected: repo.id == highlighted))
                            .help(repo.fullName)
                            .id(repo.id)
                        }
                    }
                }
                .padding(6)
            }
            .frame(height: rows == 0 ? nil : height)
            .overlay {
                if rows == 0 {
                    Text("No repository matches \"\(query)\".")
                        .foregroundStyle(.secondary)
                        .padding(12)
                }
            }
            .onChange(of: highlighted) { _, id in
                if let id { proxy.scrollTo(id) }
            }
        }
        .frame(maxWidth: .infinity, minHeight: rows == 0 ? 40 : nil)
        .modifier(SettingsInputChrome(focused: false))
    }

    private static let maxHeight: CGFloat = 280

    /// Loads the list again; a small spinner in its place while it does.
    @ViewBuilder
    private var refreshButton: some View {
        if model.isRefreshing {
            DelayedSpinner(detail: "welcome repos refresh")
                .frame(width: 24, height: 24)
        } else {
            Button { model.refreshRepositories() } label: {
                Image(systemName: "arrow.clockwise")
                    .font(.system(size: 11, weight: .semibold))
            }
            .buttonStyle(BottomBarButtonStyle(height: 24, horizontalPadding: 0))
            .help("Reload the repositories")
            .accessibilityLabel("Reload the repositories")
        }
    }

    private func pick(_ repo: GitHubRepository) {
        UITiming.select("welcome repo")
        model.selectRepository(repo)
        query = repo.fullName
        highlighted = repo.id
        isOpen = false
    }

    private func pickHighlighted() {
        let repos = shown.flatMap(\.repos)
        guard let repo = repos.first(where: { $0.id == highlighted }) ?? repos.first else { return }
        pick(repo)
    }

    /// Up/Down: opens the list, or moves the highlight, stopping at the ends.
    private func move(by step: Int) -> KeyPress.Result {
        guard isOpen else {
            isOpen = true
            return .handled
        }
        let ids = shown.flatMap { $0.repos.map(\.id) }
        guard !ids.isEmpty else { return .handled }
        let index = highlighted.flatMap(ids.firstIndex(of:)).map { $0 + step } ?? (step > 0 ? 0 : ids.count - 1)
        highlighted = ids[min(max(index, 0), ids.count - 1)]
        return .handled
    }

    /// `groups` with the repositories that every keyword of `query` hits, best first, grouped by owner in the order of
    /// each owner's best hit; all of `groups` for an empty query.
    @concurrent
    private nonisolated static func filter(_ groups: Groups, query: String) async -> Groups {
        guard !FuzzyRank.keywords(in: query).isEmpty else { return groups }
        let repos = groups.flatMap(\.repos)
        let texts = repos.map { [$0.name.lowercased(), $0.fullName.lowercased()] }
        var result: Groups = []
        for index in FuzzyRank.rank(texts, query: query, limit: repos.count) {
            let repo = repos[index]
            if let group = result.firstIndex(where: { $0.owner == repo.owner.login }) {
                result[group].repos.append(repo)
            } else {
                result.append((owner: repo.owner.login, repos: [repo]))
            }
        }
        return result
    }
}

/// The repositories opened lately; a click opens one in this tab.
private struct RecentCard: View {
    let model: WelcomeModel
    private var recents: RecentRepos { RecentRepos.shared }

    var body: some View {
        SectionCard("Recent", systemImage: "clock", count: recents.urls.count, contentPadding: 6) {
            if recents.urls.isEmpty {
                Text("No recent repositories yet.")
                    .foregroundStyle(.secondary)
                    .padding(.horizontal, 6)
                    .padding(.vertical, 4)
                    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
            } else {
                // The panel's whole height, scrolling inside when the rows don't fit.
                CardScrollView {
                    VStack(alignment: .leading, spacing: 2) {
                        ForEach(recents.urls, id: \.path) { url in
                            Button { model.openRecent(url) } label: {
                                Label {
                                    HStack(spacing: 8) {
                                        Text(url.lastPathComponent)
                                            .lineLimit(1)
                                        Text(url.deletingLastPathComponent().path)
                                            .font(.settingsCaption)
                                            .lineLimit(1)
                                            .truncationMode(.middle)
                                    }
                                } icon: {
                                    Image(systemName: "folder")
                                }
                            }
                            .buttonStyle(SidebarItemStyle(selected: false))
                            .help(url.path)
                            .contextMenu {
                                Button("Remove from Recent") { recents.remove(url) }
                            }
                        }
                    }
                }
                .frame(maxHeight: .infinity)
            }
        }
        .frame(maxHeight: .infinity)
    }
}
