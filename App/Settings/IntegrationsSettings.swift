// Settings › Integrations, per profile: the profile's code host accounts, one per host (`HostingAccountsSection`, the
// accounts without the profile picker, is the onboarding's account step). Add Account connects GitHub
// (github.com) or a GitHub Enterprise Server host by signing in with GitHub (OAuth device flow, github.com only), by
// pasting a personal access token, or by importing the GitHub CLI's token; GitLab (gitlab.com) or a GitLab
// Self-Managed host (with an optional base path) by pasting a personal access token, or by signing in with GitLab
// (device flow) with Histq's application on gitlab.com or the account's own Application ID on Self-Managed; Bitbucket
// (bitbucket.org) by pasting an Atlassian API token, or by signing in with Bitbucket (authorization code in the browser,
// back through `LoopbackRedirect`) when the build has Histq's client ID and secret. Each token is checked with
// `GET /user` before it is saved in the login Keychain (`HostingTokens`), and the profile keeps only the host (and base
// path), the login and a Self-Managed sign-in's Application ID.
// A sign-in that returns a refresh token or an expiry also saves the account's `.oauth` record, and an account whose
// sign-in can no longer be renewed says so. Disconnect deletes that account's Keychain items. Tokens are never logged,
// shown or kept in the page's state longer than the check.
import AppKit
import HistqCore
import SwiftUI

struct IntegrationsSettings: View {
    /// The profile the page edits, shared with the Profiles and SSH pages; nil (or a deleted one) shows the first.
    @Binding var profileID: UUID?
    let onShowProfiles: () -> Void
    /// Set by the onboarding's step (`HostingAccountsSection`): the accounts only, without the profile picker or the
    /// page's gate, and this row when there is no profile.
    var embedded: NoProfileRow? = nil
    /// The window's modal (`ModalHost`) asks before a disconnect.
    @Environment(WindowModel.self) private var model
    /// The account being added (Add Account), nil when no connect form shows.
    @State private var adding: AddKind?
    /// The GitHub Enterprise Server or GitLab Self-Managed host typed for the next connection.
    @State private var hostDraft = ""
    /// The GitLab Self-Managed base path typed for the next connection (`gitlab` for `https://example.com/gitlab`).
    @State private var basePathDraft = ""
    /// The Application ID of the GitLab Self-Managed instance's own OAuth application, typed for "Sign in with GitLab".
    @State private var applicationIDDraft = ""
    @State private var pastedToken = ""
    /// Whether the Keychain holds each account's token (by host), read off the main thread at each select of the page.
    @State private var tokenStored: [String: Loadable<Bool>] = [:]
    /// The hosts whose OAuth sign-in can no longer be renewed (`HostingTokens.isSignInExpired`), read with
    /// `tokenStored`.
    @State private var signInExpired: Set<String> = []
    @State private var activity: Activity = .idle
    /// The connection in flight (a check, an import, a device flow's polling); cancelled by Cancel, a profile switch
    /// and the Settings modal closing.
    @State private var connectTask: Task<Void, Never>?
    @State private var copied = false
    /// The way to connect picked at the top of the account group; each shows only its own rows.
    @State private var method: ConnectMethod = .signIn
    /// The GitHub CLI's accounts on the typed host (`gh auth status --json`), read off the main thread while the GitHub
    /// CLI method shows; nil while loading or when this gh cannot list them (Import then takes the active account).
    @State private var cliAccounts: [CLIAccount]?

    private enum ConnectMethod: Hashable, CaseIterable {
        case signIn, token, cli

        func title(_ kind: HostingKind) -> String {
            switch self {
            case .signIn: "Sign in with \(kind.name)"
            case .token: kind == .bitbucketCloud ? "API token" : "Personal access token"
            case .cli: "GitHub CLI"
            }
        }
    }

    /// The entries of the Add Account menu.
    private enum AddKind: CaseIterable {
        case github, enterprise, gitlab, gitlabSelfManaged, bitbucket

        var title: String {
            switch self {
            case .github: "GitHub"
            case .enterprise: "GitHub Enterprise Server"
            case .gitlab: "GitLab"
            case .gitlabSelfManaged: "GitLab Self-Managed"
            case .bitbucket: "Bitbucket"
            }
        }

        var kind: HostingKind {
            switch self {
            case .github, .enterprise: .github
            case .gitlab, .gitlabSelfManaged: .gitlab
            case .bitbucket: .bitbucketCloud
            }
        }
    }

    private enum Activity: Equatable {
        case idle
        /// Waiting on the host or the GitHub CLI; the text says for what.
        case working(String)
        /// The device flow's code is shown; polling until the user approves it.
        case deviceCode(DeviceFlow.DeviceCode, kind: HostingKind, host: String, basePath: String?)
        case failed(String)
    }

    /// `HistqGitHubClientID` from Info.plist (build setting `HISTQ_GITHUB_CLIENT_ID`); empty until an OAuth App is
    /// registered, and then "Sign in with GitHub" is replaced by a hint.
    static let clientID = infoPlistID("HistqGitHubClientID")

    /// `HistqGitLabClientID` from Info.plist (build setting `HISTQ_GITLAB_CLIENT_ID`): Histq's GitLab application on
    /// gitlab.com; empty until one is registered, and then gitlab.com has no "Sign in with GitLab".
    static let gitLabClientID = infoPlistID("HistqGitLabClientID")

    /// `HistqBitbucketClientID` and `HistqBitbucketClientSecret` from Info.plist (build settings
    /// `HISTQ_BITBUCKET_CLIENT_ID`, and `HISTQ_BITBUCKET_CLIENT_SECRET` from the untracked `Config/Secrets.xcconfig`):
    /// Histq's Bitbucket OAuth client. Without either, Bitbucket connects with an API token only. The secret is never
    /// shown or logged.
    static let bitbucketClientID = infoPlistID("HistqBitbucketClientID")
    private static let bitbucketClientSecret = infoPlistID("HistqBitbucketClientSecret")

    private static func infoPlistID(_ key: String) -> String {
        let value = (Bundle.main.object(forInfoDictionaryKey: key) as? String ?? "")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        // An unexpanded `$(…)` would mean the build setting is missing, not a client ID.
        return value.hasPrefix("$(") ? "" : value
    }

    private var library: ProfileLibrary { .shared }

    /// The row shown in place of the accounts when there is no profile: a title, a hint and a button that leads to one.
    struct NoProfileRow {
        let title: String
        let hint: String
        let button: String
        let action: () -> Void
    }

    var body: some View {
        Group {
            if embedded != nil {
                // One view, as `SettingsPageGate` gives: `onDisappear` below must not run for each of its groups (the
                // device code's goes when the approval comes, while the token is checked and saved).
                VStack(alignment: .leading, spacing: SettingsMetrics.cardSpacing) {
                    if case .loaded(let store) = library.state { loaded(store) }
                }
            } else {
                SettingsPageGate(section: .integrations, isLoaded: !isLoading) {
                    switch library.state {
                    case .loaded(let store): loaded(store)
                    case .failed(let message): ProfileStoreFailedCard(message: message)
                    case .idle, .loading: EmptyView()
                    }
                } skeleton: {
                    SettingsSkeletonGroup(rows: 1)
                    SettingsSkeletonGroup(rows: 2)
                }
            }
        }
        // Leaving the screen (Settings closing, the onboarding's step changing) cancels a connection in flight.
        .onDisappear { cancelConnection() }
        #if DEBUG
        .onChange(of: isLoading, initial: true) { debugFakeLogin() }
        #endif
    }

    private var isLoading: Bool {
        switch library.state {
        case .idle, .loading: true
        case .loaded, .failed: false
        }
    }

    @ViewBuilder
    private func loaded(_ store: ProfileStore) -> some View {
        if let profile = store.profile(id: profileID ?? UUID()) ?? store.profiles.first {
            if embedded == nil { profileGroup(store, current: profile) }
            accountsGroup(profile)
                .task(id: TokenCheck(token: model.settingsToken, profileID: profile.id,
                                     hosts: profile.accounts.map(\.host))) {
                    await checkTokens(profile)
                }
                .onChange(of: profile.id) { closeAdd() }
            if let adding {
                if case .deviceCode(let code, let kind, let host, let basePath) = activity {
                    deviceCodeGroup(code, kind: kind, host: host, basePath: basePath)
                }
                connectGroup(profile, kind: adding)
            }
        } else {
            let row = embedded ?? NoProfileRow(
                title: "No profiles yet",
                hint: "Accounts belong to a profile. Without one, git uses your own credential helper.",
                button: "Open Profiles", action: onShowProfiles)
            SettingsGroup("Accounts") {
                LabeledContent {
                    Button(row.button, action: row.action)
                        .buttonStyle(RowTextButtonStyle(formRow: true))
                } label: {
                    Text(row.title)
                    SettingsHint(row.hint)
                }
                SettingsDivider()
                signInRow(profile: nil, host: "github.com")
            }
        }
    }

    // MARK: Profile

    private func profileGroup(_ store: ProfileStore, current: Profile) -> some View {
        SettingsGroup("Profile") {
            LabeledContent {
                CapsuleMenuPicker(label: "Profile", selection: Binding(get: { current.id }, set: { profileID = $0 }),
                                  title: Text(current.name.isEmpty ? "Unnamed" : current.name)) {
                    ForEach(store.profiles) { profile in
                        Text(profile.name.isEmpty ? "Unnamed" : profile.name).tag(profile.id)
                    }
                } footer: {
                    // Adds a profile and opens it on the Profiles page to fill in.
                    Button("Add New Profile") {
                        if let id = library.addProfile() { profileID = id }
                        onShowProfiles()
                    }
                }
            } label: {
                HStack(spacing: 8) {
                    Circle()
                        .fill(ProfileColors.color(current.color))
                        .frame(width: 10, height: 10)
                    Text("Integrations of")
                }
                SettingsHint("Each profile has its own accounts, one per host, used over HTTPS by fetch, pull, push and "
                    + "clone in its tabs.")
            }
        }
    }

    // MARK: Accounts

    private struct TokenCheck: Equatable {
        let token: Int
        let profileID: UUID
        let hosts: [String]
    }

    /// Reads whether the Keychain has each account's token (fresh, not cached: an item deleted outside Histq shows).
    private func checkTokens(_ profile: Profile) async {
        tokenStored = Dictionary(profile.accounts.map { ($0.host, .loading) }, uniquingKeysWith: { first, _ in first })
        signInExpired = []
        for account in profile.accounts {
            do {
                let token = try await HostingTokens.read(
                    profileID: profile.id, kind: account.kind, host: account.host, refresh: true)
                guard !Task.isCancelled else { return }
                tokenStored[account.host] = .loaded(token != nil)
                // An OAuth sign-in may need a token request to tell: the row shows its token first.
                if token != nil, await HostingTokens.isSignInExpired(account, profileID: profile.id) {
                    guard !Task.isCancelled else { return }
                    signInExpired.insert(account.host)
                }
            } catch {
                guard !Task.isCancelled else { return }
                tokenStored[account.host] = .failed(String(describing: error))
            }
        }
    }

    private func accountsGroup(_ profile: Profile) -> some View {
        SettingsGroup("Accounts") {
            ForEach(profile.accounts, id: \.host) { account in
                accountRow(profile, account: account)
                if account.host.lowercased() == "github.com" {
                    organizationAccessRow
                }
                SettingsDivider()
            }
            addAccountRow(profile)
            if adding == nil, case .failed(let message) = activity {
                failureText(message)
            }
        }
    }

    private func accountRow(_ profile: Profile, account: HostingAccount) -> some View {
        LabeledContent {
            Button("Disconnect") { confirmDisconnect(profile, account: account) }
                .buttonStyle(RowTextButtonStyle(formRow: true))
        } label: {
            HStack(spacing: 8) {
                Image(account.kind.logo)
                    .resizable()
                    .scaledToFit()
                    .frame(width: 16, height: 16)
                    .foregroundStyle(.primary)
                    .accessibilityHidden(true)
                Text(account.providerName)
                    .font(.body.weight(.semibold))
                Text(account.login)
                    .foregroundStyle(.secondary)
            }
            SettingsHint("Connected to \(account.address)")
            tokenStatus(tokenStored[account.host] ?? .idle, expired: signInExpired.contains(account.host))
        }
    }

    /// Histq's OAuth App exists on github.com only. An organization that restricts OAuth Apps (a new one does by
    /// default) hides its repositories until an owner grants Histq access there; no reconnect needed.
    @ViewBuilder
    private var organizationAccessRow: some View {
        if !Self.clientID.isEmpty,
           let url = URL(string: "https://github.com/settings/connections/applications/\(Self.clientID)")
        {
            SettingsDivider()
            LabeledContent {
                Button("Manage on GitHub") { NSWorkspace.shared.open(url) }
                    .buttonStyle(RowTextButtonStyle(formRow: true))
            } label: {
                Text("Organization access")
                SettingsHint("Signed in with GitHub: grant Histq access to an organization, or request it from its "
                    + "owners, then reload the repositories. A personal access token or the GitHub CLI's token "
                    + "gets its access from that token's own settings.")
            }
            .settingsSearchAnchor("Organization access")
        }
    }

    /// The Add Account menu: GitHub (github.com), a GitHub Enterprise Server host, GitLab (gitlab.com), a GitLab
    /// Self-Managed host or Bitbucket (bitbucket.org).
    private func addAccountRow(_ profile: Profile) -> some View {
        LabeledContent {
            Menu {
                ForEach(AddKind.allCases, id: \.self) { kind in
                    Button(kind.title) { startAdd(kind) }
                }
            } label: {
                HStack(spacing: MenuChevron.gap) {
                    Text("Add Account")
                    MenuChevron()
                }
            }
            .menuStyle(.button)
            .buttonStyle(BottomBarButtonStyle(height: 24, horizontalPadding: 12, menu: true))
            .menuIndicator(.hidden)
            .fixedSize()
            .disabled(isBusy)
        } label: {
            Text(profile.accounts.isEmpty ? "No accounts yet" : "Add account")
            SettingsHint("GitHub, GitLab or Bitbucket, on their own sites or on your own host: one account per host.")
        }
    }

    @ViewBuilder
    private func tokenStatus(_ stored: Loadable<Bool>, expired: Bool) -> some View {
        switch stored {
        case .loaded(true) where expired:
            Text("The sign-in expired and could not be renewed. Disconnect, then connect again.")
                .font(.settingsCaption)
                .foregroundStyle(.red)
        case .loaded(true):
            SettingsHint("The token is in your login Keychain.")
        case .loaded(false):
            Text("The token is missing from the Keychain. Disconnect, then connect again.")
                .font(.settingsCaption)
                .foregroundStyle(.red)
        case .failed(let message):
            Text("The Keychain could not be read: \(message)")
                .font(.settingsCaption)
                .foregroundStyle(.red)
        case .idle, .loading:
            SkeletonLine(width: 200, height: 11)
        }
    }

    private func confirmDisconnect(_ profile: Profile, account: HostingAccount) {
        model.presentModal(.confirmation(ModalConfirmation(
            title: "Disconnect \(account.login)?",
            message: "Deletes the profile's token for \(account.host) from your login Keychain. Git then uses your own "
                + "credential helper for \(account.host). The token stays valid on \(account.providerName) until you "
                + "revoke it there.",
            button: "Disconnect", isDestructive: true) { disconnect(profile.id, account: account) }))
    }

    /// Deletes only this account's Keychain items (token and `.oauth` record), then removes the account from the
    /// profile.
    private func disconnect(_ id: UUID, account: HostingAccount) {
        Task {
            do {
                try await HostingTokens.delete(profileID: id, kind: account.kind, host: account.host)
                library.removeAccount(forHost: account.host, of: id)
                tokenStored[account.host] = nil
            } catch {
                if !isBusy { activity = .failed("The token could not be deleted: \(error)") }
            }
        }
    }

    // MARK: Connect

    private var isBusy: Bool {
        switch activity {
        case .working, .deviceCode: true
        case .idle, .failed: false
        }
    }

    /// The host of the account being added, lowercased: github.com for GitHub, gitlab.com for GitLab, bitbucket.org
    /// for Bitbucket, the typed host for GitHub Enterprise Server and GitLab Self-Managed; nil when nothing is added or
    /// the typed text is empty or not a host name.
    private var draftHost: String? {
        switch adding {
        case .github: return "github.com"
        case .gitlab: return "gitlab.com"
        case .bitbucket: return BitbucketCloudClient.host
        case .enterprise, .gitlabSelfManaged:
            return HostingHTTP.validatedHost(hostDraft.trimmingCharacters(in: .whitespacesAndNewlines))
        case nil: return nil
        }
    }

    /// The GitLab Self-Managed base path as GitLab's client reads it (outer `/` trimmed, "" at the root); "" for the
    /// other kinds, nil when the typed text is not a plain path.
    private var draftBasePath: String? {
        guard adding == .gitlabSelfManaged else { return "" }
        let text = basePathDraft.trimmingCharacters(in: .whitespacesAndNewlines)
        return (try? GitLabClient(basePath: text) { _ in "" })?.basePath.joined(separator: "/")
    }

    /// `draftHost` when the profile has no account there yet (one account per host) and the base path is plain, else
    /// nil.
    private func connectableHost(_ profile: Profile) -> String? {
        guard let host = draftHost, draftBasePath != nil, profile.account(forHost: host) == nil else { return nil }
        return host
    }

    /// The typed Self-Managed Application ID, trimmed; nil when empty.
    private var draftApplicationID: String? {
        let text = applicationIDDraft.trimmingCharacters(in: .whitespacesAndNewlines)
        return text.isEmpty ? nil : text
    }

    /// The OAuth client ID "Sign in with" uses for `kind`: Histq's on github.com, gitlab.com and bitbucket.org (there
    /// only with its secret), the typed Application ID on GitLab Self-Managed; nil when there is none (always on GitHub
    /// Enterprise Server).
    private func signInClientID(_ kind: AddKind) -> String? {
        let id = switch kind {
        case .github: Self.clientID
        case .gitlab: Self.gitLabClientID
        case .gitlabSelfManaged: draftApplicationID ?? ""
        case .bitbucket: Self.bitbucketClientSecret.isEmpty ? "" : Self.bitbucketClientID
        case .enterprise: ""
        }
        return id.isEmpty ? nil : id
    }

    /// Histq's OAuth App exists on github.com only (without a client ID its row says how to set one); Enterprise hosts
    /// connect with a token or the GitHub CLI. GitLab hosts connect with a token, or sign in when there is an
    /// application ID (Histq's on gitlab.com, the typed one on Self-Managed). Bitbucket connects with an API token, or
    /// signs in when the build has Histq's client.
    private func methods(_ kind: AddKind) -> [ConnectMethod] {
        switch kind {
        case .github: ConnectMethod.allCases
        case .enterprise: [.token, .cli]
        case .gitlab, .gitlabSelfManaged, .bitbucket: signInClientID(kind) == nil ? [.token] : [.signIn, .token]
        }
    }

    /// The picked method, or the kind's first when it is not offered (the Application ID was cleared).
    private func shownMethod(_ kind: AddKind) -> ConnectMethod {
        let methods = methods(kind)
        return methods.contains(method) ? method : methods[0]
    }

    private func startAdd(_ kind: AddKind) {
        closeAdd()
        if !methods(kind).contains(method) { method = methods(kind)[0] }
        adding = kind
    }

    /// Closes the add form: cancels its connection and forgets what was typed.
    private func closeAdd() {
        cancelConnection()
        adding = nil
        hostDraft = ""
        basePathDraft = ""
        applicationIDDraft = ""
        pastedToken = ""
        if case .failed = activity { activity = .idle }
    }

    private func connectGroup(_ profile: Profile, kind: AddKind) -> some View {
        SettingsGroup("Add \(kind.title) account", description: "Fetch, pull, push and clone over HTTPS use the token "
            + "for this host; nothing else gets it. It is checked with \(kind.kind.name), then kept in your login "
            + "Keychain.") {
            LabeledContent {
                HStack(spacing: 8) {
                    CapsuleMenuPicker(label: "Method", selection: $method,
                                      title: Text(shownMethod(kind).title(kind.kind))) {
                        ForEach(methods(kind), id: \.self) { Text($0.title(kind.kind)).tag($0) }
                    }
                    .disabled(isBusy)
                    Button("Cancel", action: closeAdd)
                        .buttonStyle(RowTextButtonStyle(formRow: true))
                }
            } label: {
                Text("Method")
            }
            SettingsDivider()
            if kind == .enterprise || kind == .gitlabSelfManaged {
                hostRow(kind)
                SettingsDivider()
            }
            if kind == .gitlabSelfManaged {
                basePathRow
                SettingsDivider()
                applicationIDRow
                SettingsDivider()
            }
            switch shownMethod(kind) {
            case .signIn: signInRow(profile: profile, kind: kind, host: connectableHost(profile))
            case .token: tokenRow(profile, kind: kind)
            case .cli: cliRow(profile)
            }
            if let host = draftHost, profile.account(forHost: host) != nil {
                failureText("This profile already has an account on \(host). Disconnect it first.")
            }
            activityLine
        }
    }

    private func hostRow(_ kind: AddKind) -> some View {
        let example = kind == .gitlabSelfManaged ? "gitlab.example.com" : "github.example.com"
        return LabeledContent {
            TextField("Host", text: $hostDraft, prompt: Text(verbatim: example))
                .textFieldStyle(.settings)
                .frame(maxWidth: 240)
                .labelsHidden()
                .disabled(isBusy)
        } label: {
            Text("Host")
            if draftHost == nil, !hostDraft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                Text("Enter a host name such as \(example), without https://.")
                    .font(.settingsCaption)
                    .foregroundStyle(.red)
            } else {
                SettingsHint("Your \(kind.title) host.")
            }
        }
    }

    private var basePathRow: some View {
        LabeledContent {
            TextField("Base path", text: $basePathDraft, prompt: Text(verbatim: "gitlab"))
                .textFieldStyle(.settings)
                .frame(maxWidth: 240)
                .labelsHidden()
                .disabled(isBusy)
        } label: {
            Text("Base path")
            if draftBasePath == nil {
                Text("Enter only the path, such as gitlab or tools/gitlab: letters, digits, -, _, . and ~.")
                    .font(.settingsCaption)
                    .foregroundStyle(.red)
            } else {
                SettingsHint("Optional: only when GitLab lives under a path, such as gitlab for "
                    + "https://example.com/gitlab.")
            }
        }
    }

    private var applicationIDRow: some View {
        LabeledContent {
            TextField("Application ID", text: $applicationIDDraft)
                .textFieldStyle(.settings)
                .frame(maxWidth: 240)
                .labelsHidden()
                .disabled(isBusy)
        } label: {
            Text("Application ID")
            SettingsHint("Optional: for Sign in with GitLab, the ID of an application on this GitLab that is not "
                + "confidential, has the device authorization grant on and the scopes api, read_user, read_repository "
                + "and write_repository.")
        }
    }

    private func tokenRow(_ profile: Profile, kind: AddKind) -> some View {
        LabeledContent {
            HStack(spacing: 8) {
                SecureField("Token", text: $pastedToken, prompt: tokenPrompt(kind.kind))
                    .textFieldStyle(.settings)
                    .frame(maxWidth: 240)
                    .labelsHidden()
                    .onSubmit { savePasted(profile) }
                Button("Save") { savePasted(profile) }
                    .buttonStyle(RowTextButtonStyle(formRow: true))
                    .disabled(connectableHost(profile) == nil
                        || pastedToken.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            }
            .disabled(isBusy)
        } label: {
            Text(ConnectMethod.token.title(kind.kind))
            switch kind.kind {
            case .gitlab:
                SettingsHint("Scopes api, read_user, read_repository and write_repository. A fine-grained token with "
                    + "the same access works too.")
            case .bitbucketCloud:
                SettingsHint("An Atlassian API token for Bitbucket with the scopes read:user, read:workspace, "
                    + "read:repository, write:repository, read:pullrequest and write:pullrequest (each :bitbucket).")
            case .github:
                SettingsHint("Classic: the repo scope (and workflow to push workflow files). Fine-grained: Contents "
                    + "read and write.")
            }
        }
    }

    /// The token field's placeholder: the token's prefix on GitHub and GitLab.
    private func tokenPrompt(_ kind: HostingKind) -> Text {
        switch kind {
        case .github: Text(verbatim: "ghp_…")
        case .gitlab: Text(verbatim: "glpat-…")
        case .bitbucketCloud: Text("API token")
        }
    }

    private func cliRow(_ profile: Profile) -> some View {
        let accounts = cliAccounts ?? []
        return LabeledContent {
            Group {
                if accounts.count > 1 {
                    // Several gh accounts on this host (gh auth switch): pick the one to import, active or not.
                    Menu {
                        ForEach(accounts, id: \.login) { account in
                            Button(account.active ? "\(account.login) (active)" : account.login) {
                                importFromCLI(profile, user: account.login)
                            }
                            .disabled(account.state != "success")
                        }
                    } label: {
                        HStack(spacing: MenuChevron.gap) {
                            Text("Import")
                            MenuChevron()
                        }
                    }
                    .menuStyle(.button)
                    .buttonStyle(BottomBarButtonStyle(height: 24, horizontalPadding: 12, menu: true))
                    .menuIndicator(.hidden)
                    .fixedSize()
                } else {
                    Button("Import") { importFromCLI(profile, user: nil) }
                        .buttonStyle(RowTextButtonStyle(formRow: true))
                }
            }
            .disabled(connectableHost(profile) == nil || isBusy)
        } label: {
            Text("GitHub CLI")
            if accounts.count > 1 {
                SettingsHint("Pick one of gh's \(accounts.count) accounts for this host (gh auth token --hostname "
                    + "\(draftHost ?? "<host>") --user <login>).")
            } else {
                SettingsHint("Uses the token of gh auth login for this host (gh auth token --hostname "
                    + "\(draftHost ?? "<host>")).")
            }
        }
        .task(id: draftHost) { await loadCLIAccounts(host: draftHost) }
    }

    /// Lists gh's accounts on `host`, a moment after the host field stops changing (one gh run, not one per key).
    private func loadCLIAccounts(host: String?) async {
        cliAccounts = nil
        guard let host else { return }
        try? await Task.sleep(for: .milliseconds(300))
        guard !Task.isCancelled else { return }
        let accounts = await Self.cliAccounts(host: host)
        guard !Task.isCancelled else { return }
        cliAccounts = accounts
    }

    /// "Sign in with GitHub" or "Sign in with GitLab": the device flow's button, or the hint when this build has no
    /// GitHub OAuth App client ID (GitLab offers the method only with an application ID); "Sign in with Bitbucket":
    /// the authorization code flow's button (offered only with Histq's client).
    private func signInRow(profile: Profile?, kind: AddKind = .github, host: String?) -> some View {
        let clientID = signInClientID(kind)
        return LabeledContent {
            if clientID != nil {
                Button("Sign In") {
                    guard let profile, let host else { return }
                    if kind == .bitbucket {
                        startCodeFlow(profile, host: host)
                    } else {
                        startDeviceFlow(profile, kind: kind, host: host)
                    }
                }
                .buttonStyle(RowTextButtonStyle(formRow: true, prominent: true))
                .disabled(profile == nil || host == nil || isBusy)
            }
        } label: {
            Text("Sign in with \(kind.kind.name)")
            if clientID == nil {
                SettingsHint("Register a GitHub OAuth App and set HISTQ_GITHUB_CLIENT_ID")
            } else if kind == .bitbucket {
                SettingsHint("Opens Bitbucket in your browser, where you grant Histq access.")
            } else {
                SettingsHint("Opens \(kind.kind.name) in your browser, where you enter a one-time code.")
            }
        }
        .settingsSearchAnchor("Sign in with \(kind.kind.name)")
    }

    @ViewBuilder
    private var activityLine: some View {
        switch activity {
        case .working(let text):
            HStack(spacing: 8) {
                ProgressView()
                    .controlSize(.small)
                Text(text)
                    .font(.settingsCaption)
                    .foregroundStyle(.secondary)
                Spacer(minLength: 0)
                Button("Cancel", action: cancelConnection)
                    .buttonStyle(RowTextButtonStyle(formRow: true))
            }
            .padding(.top, 8)
        case .failed(let message):
            failureText(message)
        case .idle, .deviceCode:
            EmptyView()
        }
    }

    private func failureText(_ message: String) -> some View {
        Text(message)
            .font(.settingsCaption)
            .foregroundStyle(.red)
            .fixedSize(horizontal: false, vertical: true)
            .padding(.top, 8)
    }

    /// The device flow's code, big, with Copy and Open GitHub (or GitLab; both already done once when the code came),
    /// while the app polls for the approval.
    private func deviceCodeGroup(
        _ code: DeviceFlow.DeviceCode, kind: HostingKind, host: String, basePath: String?
    ) -> some View {
        SettingsGroup("Sign in with \(kind.name)", description: "The code is copied and \(kind.name) is open in your "
            + "browser: paste it there. Histq connects as soon as you approve it.") {
            HStack(spacing: 12) {
                Text(code.userCode)
                    .font(.system(size: 28, weight: .semibold, design: .monospaced))
                    .textSelection(.enabled)
                Spacer(minLength: 12)
                Button(copied ? "Copied" : "Copy Code") {
                    NSPasteboard.general.clearContents()
                    NSPasteboard.general.setString(code.userCode, forType: .string)
                    copied = true
                }
                .buttonStyle(RowTextButtonStyle(formRow: true))
                Button("Open \(kind.name)") {
                    NSWorkspace.shared.open(
                        Self.verificationURL(code, kind: kind, host: host, basePath: basePath, complete: true))
                }
                .buttonStyle(RowTextButtonStyle(formRow: true, prominent: true))
            }
            SettingsDivider()
            HStack(spacing: 8) {
                ProgressView()
                    .controlSize(.small)
                Text("Waiting for the approval at "
                    + "\(Self.verificationURL(code, kind: kind, host: host, basePath: basePath).absoluteString)…")
                    .font(.settingsCaption)
                    .foregroundStyle(.secondary)
                Spacer(minLength: 0)
                Button("Cancel", action: cancelConnection)
                    .buttonStyle(RowTextButtonStyle(formRow: true))
            }
        }
    }

    /// The flow's verification URL (with `complete`, the one with the code filled in when the host sent it) when it is
    /// https on the flow's host and port (`host` as validated, with its port if it has one) without userinfo, else
    /// `https://<host>/login/device` on GitHub and `https://<host>[/<basePath>]/oauth/device` on GitLab: the URL comes
    /// from the server, and the browser should only ever open the host the user typed.
    private static func verificationURL(
        _ code: DeviceFlow.DeviceCode, kind: HostingKind, host: String, basePath: String?, complete: Bool = false
    ) -> URL {
        let hostParts = host.split(separator: ":", maxSplits: 1).map(String.init)
        func onHost(_ text: String?) -> URL? {
            guard let text, let url = URL(string: text), url.scheme?.lowercased() == "https",
                  url.user == nil, url.password == nil,
                  url.host?.lowercased() == hostParts.first, url.port == hostParts.dropFirst().first.flatMap({ Int($0) })
            else { return nil }
            return url
        }
        if complete, let url = onHost(code.verificationURIComplete) { return url }
        if let url = onHost(code.verificationURI) { return url }
        let path = kind == .gitlab ? (basePath.map { "/" + $0 } ?? "") + "/oauth/device" : "/login/device"
        return URL(string: "https://\(host)\(path)") ?? URL(string: "https://github.com/login/device")!
    }

    private func cancelConnection() {
        connectTask?.cancel()
        connectTask = nil
        if isBusy { activity = .idle }
    }

    private func savePasted(_ profile: Profile) {
        let token = pastedToken.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !token.isEmpty, let host = connectableHost(profile), let kind = adding?.kind,
              let basePath = draftBasePath, !isBusy
        else { return }
        connect(profile.id, kind: kind, host: host, basePath: basePath.isEmpty ? nil : basePath,
                status: "Checking the token with \(kind.name)…") { token }
    }

    /// `user`: the gh account to import, nil for the host's active one.
    private func importFromCLI(_ profile: Profile, user: String?) {
        guard let host = connectableHost(profile), !isBusy else { return }
        connect(profile.id, host: host, status: "Reading the GitHub CLI's token…") {
            try await Self.cliToken(host: host, user: user)
        }
    }

    /// The device flow on `host`. A GitLab Self-Managed account keeps the Application ID it signed in with (its token
    /// renews with it); on github.com and gitlab.com the account keeps none (Histq's own).
    private func startDeviceFlow(_ profile: Profile, kind: AddKind, host: String) {
        guard !isBusy, profile.account(forHost: host) == nil, let clientID = signInClientID(kind),
              let draftPath = draftBasePath
        else { return }
        connectTask?.cancel()
        copied = false
        let hostKind = kind.kind
        let basePath = draftPath.isEmpty ? nil : draftPath
        let ownClientID = kind == .gitlabSelfManaged ? clientID : nil
        activity = .working("Asking \(hostKind.name) for a code…")
        let id = profile.id
        connectTask = Task {
            do {
                let flow = try DeviceFlow(kind: hostKind, host: host, basePath: basePath, clientID: clientID)
                let code: DeviceFlow.DeviceCode
                do {
                    code = try await flow.start()
                } catch let error where hostKind == .gitlab && Self.lacksDeviceGrant(error) {
                    throw NoDeviceGrant()
                }
                try Task.checkCancellation()
                activity = .deviceCode(code, kind: hostKind, host: host, basePath: basePath)
                // As `gh auth login --web`: the code goes to the clipboard and the browser opens, ready to paste.
                NSPasteboard.general.clearContents()
                NSPasteboard.general.setString(code.userCode, forType: .string)
                copied = true
                NSWorkspace.shared.open(
                    Self.verificationURL(code, kind: hostKind, host: host, basePath: basePath, complete: true))
                let token = try await flow.waitForToken(code)
                try Task.checkCancellation()
                activity = .working("Checking the token with \(hostKind.name)…")
                try await finishConnect(
                    id, kind: hostKind, host: host, basePath: basePath, token: token.accessToken,
                    refreshToken: token.refreshToken, expiresIn: token.expiresIn, oauthClientID: ownClientID)
            } catch {
                fail(error, kind: hostKind)
            }
        }
    }

    /// "Sign in with Bitbucket": Bitbucket's authorize page in the browser, which sends the code back to Histq through
    /// the loopback redirect; the code is then exchanged with Histq's client secret. The account keeps no client ID
    /// (Histq's renews its token).
    private func startCodeFlow(_ profile: Profile, host: String) {
        guard !isBusy, profile.account(forHost: host) == nil, let clientID = signInClientID(.bitbucket) else { return }
        connectTask?.cancel()
        let waiting = "Waiting for you to grant access on Bitbucket in your browser…"
        activity = .working(waiting)
        let id = profile.id
        let secret = Self.bitbucketClientSecret
        connectTask = Task {
            do {
                let flow = try OAuthCodeFlow.bitbucketCloud(clientID: clientID, clientSecret: secret)
                let attempt = flow.start()
                // A request without this sign-in's state (another page probing the port) is ignored, not fatal.
                let port = UInt16(flow.redirectURI.port ?? 0)
                let target = try await LoopbackRedirect.callback(
                    port: port, path: flow.redirectURI.path(), opening: attempt.url,
                    portBusy: {
                        activity = .working("Port \(port) is busy (the last sign-in may still hold it): waiting for "
                            + "it to free up…")
                    },
                    listening: { activity = .working(waiting) }
                ) { target in
                    do {
                        _ = try flow.code(fromCallback: target, for: attempt)
                        return true
                    } catch OAuthCodeFlow.CodeFlowError.invalidCallback {
                        return false
                    } catch {
                        return true
                    }
                }
                try Task.checkCancellation()
                let code = try flow.code(fromCallback: target, for: attempt)
                activity = .working("Getting the token from Bitbucket…")
                let token = try await flow.exchange(code, for: attempt)
                try Task.checkCancellation()
                activity = .working("Checking the token with Bitbucket…")
                try await finishConnect(
                    id, kind: .bitbucketCloud, host: host, token: token.accessToken, refreshToken: token.refreshToken,
                    expiresIn: token.expiresIn)
            } catch {
                fail(error, kind: .bitbucketCloud)
            }
        }
    }

    /// A GitLab whose device-code request fails because it has no device authorization grant.
    private struct NoDeviceGrant: Error {}

    /// Whether a GitLab device-code request failed for want of the device authorization grant: a 404 (no such
    /// endpoint), `unsupported_grant_type`, or `invalid_request` about the device grant.
    private static func lacksDeviceGrant(_ error: Error) -> Bool {
        switch error {
        case HostingError.notFound: true
        case DeviceFlow.DeviceFlowError.failed(code: "unsupported_grant_type", description: _): true
        case DeviceFlow.DeviceFlowError.failed(code: "invalid_request", description: let description?):
            description.localizedCaseInsensitiveContains("device")
        default: false
        }
    }

    /// The paste and import paths: `source` gives the token, then it is checked and saved.
    private func connect(
        _ id: UUID, kind: HostingKind = .github, host: String, basePath: String? = nil, status: String,
        source: @escaping @Sendable () async throws -> String
    ) {
        connectTask?.cancel()
        activity = .working(status)
        connectTask = Task {
            do {
                let token = try await source()
                try Task.checkCancellation()
                activity = .working("Checking the token with \(kind.name)…")
                try await finishConnect(id, kind: kind, host: host, basePath: basePath, token: token)
            } catch {
                fail(error, kind: kind)
            }
        }
    }

    /// Checks `token` with `GET /user`, saves it in the Keychain (with a sign-in's `refreshToken` and `expiresIn` in
    /// its `.oauth` record), then adds the profile's account (host, base path, login and the sign-in's own
    /// `oauthClientID`).
    private func finishConnect(
        _ id: UUID, kind: HostingKind = .github, host: String, basePath: String? = nil, token: String,
        refreshToken: String? = nil, expiresIn: Int? = nil, oauthClientID: String? = nil
    ) async throws {
        let login = try await Self.login(token: token, kind: kind, host: host, basePath: basePath)
        try Task.checkCancellation()
        try await HostingTokens.save(
            token, refreshToken: refreshToken, expiresIn: expiresIn, profileID: id, kind: kind, host: host)
        library.setAccount(
            HostingAccount(kind: kind, host: host, basePath: basePath, login: login, oauthClientID: oauthClientID), of: id)
        activity = .idle
        connectTask = nil
        closeAdd()
    }

    private func fail(_ error: Error, kind: HostingKind = .github) {
        // As the header says, a token stays in the page's state no longer than its check, a failed one included.
        pastedToken = ""
        if error is CancellationError || Task.isCancelled { return }
        activity = .failed(Self.message(for: error, kind: kind))
        connectTask = nil
    }

    // MARK: Off the main thread

    @concurrent
    private nonisolated static func login(
        token: String, kind: HostingKind, host: String, basePath: String?
    ) async throws -> String {
        switch kind {
        case .github:
            return try await GitHubClient(host: host, token: token).currentUser().login
        case .gitlab:
            // GitHubClient checks this itself; GitLabClient takes a provider, so the pasted text is checked here.
            guard HostingHTTP.isUsableToken(token) else { throw HostingError.invalidToken }
            return try await GitLabClient(host: host, basePath: basePath) { _ in token }.currentUser().login
        case .bitbucketCloud:
            // As GitLab's: the client takes a provider, so the pasted text is checked here.
            guard HostingHTTP.isUsableToken(token) else { throw HostingError.invalidToken }
            guard host.lowercased() == BitbucketCloudClient.host else { throw HostingError.invalidHost(host) }
            return try await BitbucketCloudClient { _ in token }.currentUser().login
        }
    }

    enum CLIError: Error, CustomStringConvertible {
        case notFound
        case failed(String)
        case noToken

        var description: String {
            switch self {
            case .notFound: "The GitHub CLI (gh) was not found. Install it with Homebrew, then run gh auth login."
            case .failed(let detail): "gh auth token failed" + (detail.isEmpty ? "." : ": \(detail)")
            case .noToken: "gh printed no usable token."
            }
        }
    }

    /// One account of `gh auth status --json hosts` (which never holds the token).
    struct CLIAccount: Decodable, Hashable, Sendable {
        let login: String
        let active: Bool
        /// "success" when gh's token for it works.
        let state: String
    }

    /// `gh <args>`, run directly (no shell) from the fixed PATH, then the login shell's.
    @concurrent
    private nonisolated static func runGH(_ args: [String], timeout: Duration) async throws -> GitResult {
        let base = await GitToolchain.writeBase()
        let folders = (GitExecutable.fixedPath + ":" + (base["PATH"] ?? "")).split(separator: ":")
        guard let gh = folders.lazy.filter({ $0.hasPrefix("/") })
            .map({ URL(filePath: String($0), directoryHint: .isDirectory).appending(path: "gh") })
            .first(where: { FileManager.default.isExecutableFile(atPath: $0.path) })
        else { throw CLIError.notFound }
        var env = base
        env["GH_PROMPT_DISABLED"] = "1"
        env["NO_COLOR"] = "1"
        return try await GitRunner(executable: gh).run(
            args, cwd: URL(filePath: NSHomeDirectory(), directoryHint: .isDirectory),
            env: env, timeout: timeout, allowedExitCodes: Set(0...255))
    }

    /// gh's accounts on `host`, active first; nil when gh is missing, fails, or is too old for `--json`.
    @concurrent
    private nonisolated static func cliAccounts(host: String) async -> [CLIAccount]? {
        struct Status: Decodable { let hosts: [String: [CLIAccount]] }
        guard let result = try? await runGH(["auth", "status", "--json", "hosts", "--hostname", host],
                                            timeout: .seconds(20)),
              result.exitCode == 0,
              let status = try? JSONDecoder().decode(Status.self, from: Data(result.text.utf8))
        else { return nil }
        return status.hosts.values.flatMap { $0 }.sorted { $0.active && !$1.active }
    }

    /// `gh auth token --hostname <host> [--user <user>]`. Its stdout is the token: only returned, never logged or put
    /// in an error (errors carry gh's stderr only).
    @concurrent
    private nonisolated static func cliToken(host: String, user: String?) async throws -> String {
        // gh may wait on its own Keychain prompt; a minute, then it is stopped.
        let result = try await runGH(
            ["auth", "token", "--hostname", host] + (user.map { ["--user", $0] } ?? []), timeout: .seconds(60))
        guard result.exitCode == 0 else {
            throw CLIError.failed(result.stderrTail.trimmingCharacters(in: .whitespacesAndNewlines))
        }
        let token = result.text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard HostingHTTP.isUsableToken(token) else { throw CLIError.noToken }
        return token
    }

    private static func message(for error: Error, kind: HostingKind) -> String {
        if let error = error as? HostingError, let message = hostMessage(for: error, kind: kind) {
            return message
        }
        return switch error {
        case HostingError.unauthorized: "GitHub refused the token: it is wrong, expired or revoked."
        case HostingError.invalidToken: "That is not a token: it has spaces or other characters a token never has."
        case GitError.timeout: "gh did not answer within a minute."
        case let error as HostingError: String(describing: error)
        case let error as DeviceFlow.DeviceFlowError: error.message(provider: kind.name)
        case let error as OAuthCodeFlow.CodeFlowError: error.message(provider: kind.name)
        case let error as LoopbackRedirect.Failure: error.description
        case is NoDeviceGrant: "This GitLab does not support device sign-in; use a token."
        case let error as CLIError: error.description
        case let error as KeychainError: "The token could not be saved: \(error)"
        default: error.localizedDescription
        }
    }

    /// GitLab's and Bitbucket's wording of the errors a token check can get (`HostingError`'s own copy names GitHub);
    /// nil for GitHub. A 403 shows the server's text: a GitLab group or instance that requires fine-grained tokens
    /// says so there (Bitbucket's text for a token without a scope is still to be seen on a real account).
    private static func hostMessage(for error: HostingError, kind: HostingKind) -> String? {
        guard kind != .github else { return nil }
        let name = kind.name
        return switch error {
        case .unauthorized: "\(name) refused the token: it is wrong, expired or revoked."
        case .forbidden(let message):
            "\(name) refused the token: " + (message.isEmpty ? "access denied (403)." : message)
        case .notFound:
            kind == .gitlab ? "GitLab's API was not found there: check the host and the base path."
                : "\(name)'s API was not found."
        case .rateLimited, .secondaryRateLimited: "\(name) asks to slow down: try again in a minute."
        case .http(let status, let message): "\(name) answered \(status)" + (message.isEmpty ? "." : ": \(message)")
        case .invalidResponse(let detail): "Unexpected answer from \(name): \(detail)"
        case .transport(let detail): "Could not reach \(name): \(detail)"
        case .invalidHost(let host):
            kind == .gitlab ? "Not a valid GitLab host or base path: \(host)" : "Not a \(name) host: \(host)"
        default: nil
        }
    }

    #if DEBUG
    /// DEBUG `-HistqGitHubFakeLogin <login>` with `-HistqKeychain memory` in state-dir mode: once the profiles are read,
    /// connects the shown profile (adding a "QA" profile when there is none) to github.com as `<login>` with a fake
    /// token in the in-memory Keychain, without asking GitHub. For QA shots of the connected state.
    private func debugFakeLogin() {
        debugFakeTokens()
        debugFakeLogin(flag: "-HistqGitHubFakeLogin", kind: .github, host: "github.com")
    }

    /// Connects the shown profile to `host` as a `kind` account, the login read from the launch flag `flag`.
    private func debugFakeLogin(flag: String, kind: HostingKind, host: String) {
        guard !isLoading, !Self.debugFakeLoginsDone.contains(flag), let login = AppState.launchFlag(flag),
              AppState.isStateDirMode, KeychainStore.shared.isInMemory, let store = library.store
        else { return }
        Self.debugFakeLoginsDone.insert(flag)
        guard let id = store.profile(id: profileID ?? UUID())?.id ?? store.profiles.first?.id
            ?? library.addProfile(identity: Profile.Identity(name: "QA", email: "qa@histq.invalid"))
        else { return }
        Task {
            try? await HostingTokens.save("histq_qa_fake_token", profileID: id, kind: kind, host: host)
            library.setAccount(HostingAccount(kind: kind, host: host, login: login), of: id)
        }
    }

    /// The fake-login flags already applied.
    private static var debugFakeLoginsDone: Set<String> = []

    /// DEBUG `-HistqGitHubFakeTokens YES` (in-memory Keychain only): a fake token for every account of every profile in
    /// `profiles.json`, on its own host, so the page shows each one connected. With `-HistqDisconnectHost <host>`, the
    /// accounts on `<host>` are then disconnected as Disconnect does, for QA shots of the page after a disconnect.
    private func debugFakeTokens() {
        guard !isLoading, !Self.debugFakeTokensDone, AppState.launchFlag("-HistqGitHubFakeTokens") == "YES",
              AppState.isStateDirMode, KeychainStore.shared.isInMemory, let store = library.store
        else { return }
        Self.debugFakeTokensDone = true
        let accounts = store.profiles.flatMap { profile in profile.accounts.map { (profile.id, $0.kind, $0.host) } }
        Task {
            for (id, kind, host) in accounts {
                try? await HostingTokens.save("histq_qa_fake_token", profileID: id, kind: kind, host: host)
            }
            if let host = AppState.launchFlag("-HistqDisconnectHost") {
                // The page reads the tokens again once the account list changes.
                for profile in store.profiles {
                    if let account = profile.account(forHost: host) { disconnect(profile.id, account: account) }
                }
            } else if let shown = store.profile(id: profileID ?? UUID()) ?? store.profiles.first {
                await checkTokens(shown)
            }
        }
    }

    private static var debugFakeTokensDone = false
    #endif
}

extension HostingKind {
    /// The host's product name: "GitHub", "GitLab" or "Bitbucket".
    var name: String {
        switch self {
        case .github: "GitHub"
        case .gitlab: "GitLab"
        case .bitbucketCloud: "Bitbucket"
        }
    }

    /// The host's logo asset (a template image).
    var logo: String {
        switch self {
        case .github: "logo-github"
        case .gitlab: "logo-gitlab"
        case .bitbucketCloud: "logo-bitbucket"
        }
    }
}

extension HostingAccount {
    /// Whether the account is on the kind's public site (github.com, gitlab.com) rather than a host of its own.
    private var isPublicSite: Bool {
        switch kind {
        case .github: host.lowercased() == "github.com"
        case .gitlab: host.lowercased() == "gitlab.com"
        case .bitbucketCloud: host.lowercased() == "bitbucket.org"
        }
    }

    /// The product name shown for the account: "GitHub" on github.com, "GitHub Enterprise Server" on any other host;
    /// "GitLab" on gitlab.com, "GitLab Self-Managed" on any other host.
    var providerName: String {
        switch kind {
        case .github: isPublicSite ? "GitHub" : "GitHub Enterprise Server"
        case .gitlab: isPublicSite ? "GitLab" : "GitLab Self-Managed"
        case .bitbucketCloud: "Bitbucket"
        }
    }

    /// The host, with the base path when there is one (`example.com/gitlab`).
    var address: String {
        basePath.map { $0.isEmpty ? host : "\(host)/\($0)" } ?? host
    }

    /// "GitHub · login" on github.com (GitLab on gitlab.com), "<provider> · login @ host[/base path]" on any other
    /// host.
    var accountTitle: String {
        isPublicSite
            ? "\(providerName) · \(login)"
            : "\(providerName) · \(login) @ \(address)"
    }
}

/// A profile's accounts (`profileID`, nil or a deleted one: the first profile) without the profile picker: the
/// onboarding's account step. With no profile, the `noProfile` row (a way to make one) above a disabled Sign In.
struct HostingAccountsSection: View {
    let profileID: UUID?
    let noProfile: IntegrationsSettings.NoProfileRow

    var body: some View {
        IntegrationsSettings(profileID: .constant(profileID), onShowProfiles: noProfile.action, embedded: noProfile)
    }
}
