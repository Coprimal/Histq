// The onboarding's setup step bodies, shown in `OnboardingCard`. Git: checked off the main actor (`WelcomeModel`), the
// git found or the Welcome page's problem card. Profile: a draft written only on Next. GitHub: `GitHubConnectSection`
// and the Welcome page's clone form, opened when the onboarding ends (`OnboardingModel.pendingClones`). AI: Show AI
// features, then the provider and its API key through `AISetup.shared`, as Settings › AI.
import HistqCore
import SwiftUI

/// The git step: the git Histq runs, or why none can run and how to get one. Next goes on either way.
struct OnboardingGitStep: View {
    let model: OnboardingModel
    /// The git the check found, read from the resolved toolchain (cached) once the check says it is usable.
    @State private var found: GitExecutable?

    var body: some View {
        let welcome = model.welcome
        VStack(alignment: .leading, spacing: 12) {
            Text("Histq runs the git installed on your Mac; it brings none of its own.")
                .fixedSize(horizontal: false, vertical: true)
            switch welcome.gitCheck {
            case .problem(let error):
                GitProblemCard(model: welcome, error: error)
                if Self.offersInstall(error) {
                    SettingsHint("Homebrew needs the Command Line Tools too: install them first, then \"brew install "
                        + "git\" works.")
                }
            case .checking, .ok:
                if let found {
                    foundRow(found)
                } else {
                    HStack(spacing: 8) {
                        DelayedSpinner(detail: "onboarding git") { model.current == .git }
                        Text("Looking for git…")
                            .foregroundStyle(.secondary)
                    }
                }
            }
        }
        .padding(SettingsMetrics.cardPadding)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .onAppear { welcome.checkGitIfNeeded() }
        // `initial`: coming Back to the step after the check ended changes nothing, so read it as it is.
        .onChange(of: welcome.gitCheck, initial: true) { _, check in
            switch check {
            case .ok: model.gitMissing = false
            case .problem: model.gitMissing = true
            case .checking: break
            }
        }
        .task(id: welcome.gitCheck) {
            guard welcome.gitCheck == .ok else { return found = nil }
            found = try? await GitToolchain.resolve().executable
        }
    }

    private func foundRow(_ git: GitExecutable) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Label {
                // The path is the file system's, shown as is.
                Text(verbatim: "git \(git.version) at \(git.url.path(percentEncoded: false))")
                    .fixedSize(horizontal: false, vertical: true)
            } icon: {
                IconImage("checkmark.circle.fill")
            }
            .foregroundStyle(.green)
            SettingsHint("To use another git, set its path in Settings › General.")
        }
    }

    /// The problems the Command Line Tools fix (the card offers to install them): the Homebrew hint applies to these.
    private static func offersInstall(_ error: GitExecutableError) -> Bool {
        switch error {
        case .commandLineToolsMissing, .tooOld, .notFound: true
        case .notExecutable, .unrecognizedVersion: false
        }
    }
}

/// The profile step: the profile name, commit identity and color of the default profile (made on Next when there is
/// none). Nothing is written before Next; empty name or email makes Next a skip.
struct OnboardingProfileStep: View {
    let model: OnboardingModel

    var body: some View {
        @Bindable var draft = model.profile
        VStack(alignment: .leading, spacing: 12) {
            Text("The name and email your commits carry. Histq hands them to git in each tab and leaves your git "
                + "config as it is.")
                .fixedSize(horizontal: false, vertical: true)
            switch draft.state {
            case .idle, .loading:
                HStack(spacing: 8) {
                    DelayedSpinner(detail: "onboarding profile") { model.current == .profile }
                    Text("Reading your profile…")
                        .foregroundStyle(.secondary)
                }
            case .failed(let message):
                failed(message)
            case .ready:
                fields(draft)
            }
            SettingsHint("Profiles keep work and personal identities apart; signing keys and SSH are in Settings › "
                + "Profiles.")
        }
        .padding(SettingsMetrics.cardPadding)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .onAppear { draft.loadIfNeeded() }
    }

    private func fields(_ draft: OnboardingProfileDraft) -> some View {
        @Bindable var draft = draft
        return Grid(alignment: .leadingFirstTextBaseline, horizontalSpacing: 12, verticalSpacing: 10) {
            GridRow {
                Text("Profile name")
                // Left empty, the profile takes the author's name: the prompt shows it.
                field("Profile name", text: $draft.profileName,
                      prompt: draft.authorName.isEmpty ? "Personal" : draft.authorName)
            }
            GridRow {
                Text("Name")
                field("Name", text: $draft.authorName, prompt: "Jane Doe")
            }
            GridRow {
                Text("Email")
                field("Email", text: $draft.email, prompt: "jane@example.com")
            }
            GridRow(alignment: .center) {
                Text("Color")
                HStack(spacing: 6) {
                    ForEach(ProfileColors.hexes, id: \.self) { hex in
                        ColorSwatch(hex: hex, selected: hex == draft.color) { draft.color = hex }
                    }
                }
            }
        }
    }

    private func field(_ title: String, text: Binding<String>, prompt: String) -> some View {
        TextField(title, text: text, prompt: Text(prompt))
            .textFieldStyle(.settings)
            .labelsHidden()
            .frame(maxWidth: 280)
    }

    /// The profile store could not be read: nothing is written (Next goes on), and Try Again reads it again.
    private func failed(_ message: String) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(message)
                .foregroundStyle(.red)
                .fixedSize(horizontal: false, vertical: true)
            Button("Try Again") { model.profile.retry() }
                .buttonStyle(RowTextButtonStyle(formRow: true))
        }
    }
}

/// What the profile step shows and writes: read once (Back keeps the typed values), written on Next. A rerun edits the
/// default (or first) profile; with none, Next adds one. Either way it becomes the default profile.
@Observable
@MainActor
final class OnboardingProfileDraft {
    enum State: Equatable {
        case idle, loading, ready
        /// The profile store could not be read (its message).
        case failed(String)
    }

    private(set) var state: State = .idle
    var profileName = ""
    var authorName = ""
    var email = ""
    var color = ProfileColors.hexes[0]

    private var library: ProfileLibrary { .shared }

    /// Fills the fields once: from the profile the step edits, else from the global git identity (read off the main
    /// actor; empty when unset or unreadable). Runs on its own, so leaving the step early does not cut it short.
    func loadIfNeeded() {
        guard state == .idle else { return }
        state = .loading
        Task {
            guard let store = await library.loaded() else {
                if case .failed(let message) = library.state { state = .failed(message) } else { state = .idle }
                return
            }
            if let profile = Self.edited(in: store) {
                profileName = profile.name
                authorName = profile.identity.name
                email = profile.identity.email
                color = profile.color
            } else {
                let identity = try? await ProfileLibrary.globalIdentity()
                authorName = identity?.name ?? ""
                email = identity?.email ?? ""
            }
            state = .ready
        }
    }

    /// Reads the profile store again after it failed.
    func retry() {
        guard case .failed = state else { return }
        library.reload()
        state = .idle
        loadIfNeeded()
    }

    /// Writes the fields into the edited profile (adding it when the store has none) and makes it the default. Nothing
    /// before the fields are read, nor with an empty name or email (Next is a skip then); an empty profile name takes
    /// the author's name.
    func commit() {
        guard state == .ready, let store = library.store else { return }
        let identity = Profile.Identity(name: authorName.trimmingCharacters(in: .whitespacesAndNewlines),
                                        email: email.trimmingCharacters(in: .whitespacesAndNewlines))
        guard !identity.name.isEmpty, !identity.email.isEmpty else { return }
        // Decided from the store as it is now, so Next, Back, Next (or a profile added in Settings meanwhile) never
        // adds a second one.
        guard let id = Self.edited(in: store)?.id ?? library.addProfile(identity: identity) else { return }
        let title = profileName.trimmingCharacters(in: .whitespacesAndNewlines)
        let color = color
        library.modify(id) { profile in
            profile.name = title.isEmpty ? identity.name : title
            profile.identity = identity
            profile.color = color
        }
        library.setDefault(id)
    }

    /// The profile the step edits: the default one, else the first; nil when there is none.
    private static func edited(in store: ProfileStore) -> Profile? {
        store.defaultProfile ?? store.profiles.first
    }
}

/// The GitHub step: the default profile's accounts (GitHub, GitLab or Bitbucket, added as in Settings ›
/// Integrations). With no profile yet, a way back to the profile step. Once connected, the clone step follows.
struct OnboardingGitHubStep: View {
    let model: OnboardingModel
    private var library: ProfileLibrary { .shared }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Connect GitHub to fetch, pull, push and clone over HTTPS, and to pick a repository to clone from "
                + "your account. You can skip it: git then uses your own credentials.")
                .fixedSize(horizontal: false, vertical: true)
            switch library.state {
            case .idle, .loading:
                HStack(spacing: 8) {
                    DelayedSpinner(detail: "onboarding github") { model.current == .github }
                    Text("Reading your profile…")
                        .foregroundStyle(.secondary)
                }
            case .failed(let message):
                VStack(alignment: .leading, spacing: 8) {
                    Text(verbatim: message)
                        .foregroundStyle(.red)
                        .fixedSize(horizontal: false, vertical: true)
                    Button("Try Again") { library.reload() }
                        .buttonStyle(RowTextButtonStyle(formRow: true))
                }
            case .loaded(let store):
                HostingAccountsSection(profileID: store.defaultProfileID, noProfile: .init(
                    title: "No profile yet",
                    hint: "An account belongs to a profile, which keeps your commit name and email.",
                    button: "Create a profile first", action: { model.back() }))
            }
        }
        .labeledContentStyle(.settingsRow)
        .padding(SettingsMetrics.cardPadding)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .onAppear { library.loadIfNeeded() }
    }
}

/// The clone step, shown only while the GitHub step's profile has an account: the Welcome page's clone form,
/// listing the account's repositories (or a URL typed in). The clone opens when the onboarding ends.
struct OnboardingCloneStep: View {
    let model: OnboardingModel
    private var library: ProfileLibrary { .shared }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Clone a repository now if you like. It opens when you finish.")
                .fixedSize(horizontal: false, vertical: true)
            // Above the form, in view: once a clone ends the form is empty again, and this line says where it went.
            cloneNote
            CloneCard(model: model.welcome)
        }
        .labeledContentStyle(.settingsRow)
        .padding(SettingsMetrics.cardPadding)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        // Once shown, and again when the account changes (e.g. in Settings over the card); disconnected, the step
        // hides, so the card moves on.
        .onChange(of: library.store.map(Self.account(in:)), initial: true) { _, shown in
            if let shown { useSource(for: shown) }
            model.leaveIfHidden()
        }
        .onAppear {
            // A launch straight on this step skipped the git step: Clone stays off until git is found.
            model.welcome.checkGitIfNeeded()
        }
    }

    /// The clones made here, that they wait for the end of the onboarding; nothing before the first.
    @ViewBuilder
    private var cloneNote: some View {
        let names = model.pendingClones.map(\.lastPathComponent)
        if !names.isEmpty {
            Label {
                // The folders' names come from the repositories' URLs or the form's folder name: plain text.
                Text(verbatim: names.count == 1 ? "\(names[0]) is cloned. It opens when you finish."
                    : "\(names.formatted(.list(type: .and))) are cloned. They open when you finish.")
                    .fixedSize(horizontal: false, vertical: true)
            } icon: {
                IconImage("checkmark.circle.fill")
            }
            .foregroundStyle(.green)
        }
    }

    /// The profile the section shows (the default one, else the first) and its first account, if any.
    private struct ShownAccount: Equatable {
        let profileID: UUID?
        let account: HostingAccount?
    }

    private static func account(in store: ProfileStore) -> ShownAccount {
        let profile = OnboardingModel.gitHubProfile(in: store)
        return ShownAccount(profileID: profile?.id, account: profile?.accounts.first)
    }

    /// The clone form follows the account: its repositories once it is connected (unless a URL is typed), the URL
    /// field otherwise. Never while a clone runs.
    private func useSource(for shown: ShownAccount) {
        let welcome = model.welcome
        guard !welcome.isCloning else { return }
        if let id = shown.profileID, let account = shown.account {
            guard welcome.cloneSource != .url || welcome.cloneURL.isEmpty else { return }
            welcome.cloneSource = .github(profileID: id, host: account.host)
        } else {
            welcome.cloneSource = .url
        }
    }
}

/// The AI step: what the AI buttons do, that the provider bills the user's own API key, and Show AI features. When on,
/// the active provider and its key, as in Settings › AI: the provider goes through `AISetup.setProvider` (`AISetup`
/// reads its pref only at launch), the key is checked by the provider and kept in the Keychain, never shown or logged.
/// A custom server's base URL and model stay in Settings › AI.
struct OnboardingAIStep: View {
    let model: OnboardingModel
    @Environment(WindowModel.self) private var window
    @AppStorage(PrefKey.aiShowFeatures.rawValue, store: Preferences.defaults)
    private var showFeatures = true
    @State private var keyDraft = ""
    @State private var keyBusy = false
    /// The last Save's outcome, for the provider shown (cleared when it changes).
    @State private var keyResult: KeyResult?

    private enum KeyResult: Equatable {
        case saved(String)
        case failed(String)
    }

    private var setup: AISetup { .shared }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("AI helps in a few places, only when you click its button:")
                .fixedSize(horizontal: false, vertical: true)
            VStack(alignment: .leading, spacing: 6) {
                bullet("Write a commit message for your staged changes, or improve one in a rebase.")
                bullet("Explain a commit, or your uncommitted changes, in plain words.")
                bullet("Suggest how to resolve a conflict, and write a pull request's description.")
            }
            note
            SettingsGroup(nil) {
                SettingsSwitchRow(title: "Show AI features",
                                  hint: "Off hides every AI button in the app. Nothing is sent until you click one.",
                                  isOn: $showFeatures)
            }
            if showFeatures {
                SettingsGroup(nil) {
                    providerRow
                    SettingsDivider()
                    if setup.provider == .custom {
                        customRow
                        SettingsDivider()
                    }
                    keyRow(setup.provider)
                }
            }
        }
        .labeledContentStyle(.settingsRow)
        .padding(SettingsMetrics.cardPadding)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        // Reads which providers have a key (off the main actor), so a key saved before shows as saved.
        .onAppear { setup.loadKeysIfNeeded() }
        .onChange(of: setup.provider) {
            keyDraft = ""
            keyResult = nil
        }
        .onDisappear { keyDraft = "" }
    }

    private func bullet(_ text: String) -> some View {
        Label {
            Text(text).fixedSize(horizontal: false, vertical: true)
        } icon: {
            IconImage("sparkles").foregroundStyle(Palette.primaryFill)
        }
    }

    /// Histq bills nothing: the provider does, on the user's own key.
    private var note: some View {
        SectionCard(nil, contentPadding: 10, tone: Palette.primaryFill) {
            Label {
                Text("Histq has no AI account of its own: you use your own API key from the provider and they bill "
                    + "you.")
                    .fixedSize(horizontal: false, vertical: true)
            } icon: {
                IconImage("key").foregroundStyle(Palette.primaryFill)
            }
        } accessory: {
            EmptyView()
        }
    }

    private var providerRow: some View {
        LabeledContent {
            CapsuleMenuPicker(label: "AI provider",
                              selection: Binding(get: { setup.provider }, set: { setup.setProvider($0) }),
                              title: Text(setup.provider.displayName)) {
                ForEach(AIProvider.allCases, id: \.self) { provider in
                    Text(provider.displayName).tag(provider)
                }
            }
        } label: {
            Text("Provider")
            SettingsHint("The AI buttons use it. Change it any time in Settings › AI.")
        }
    }

    /// A custom server's base URL (and model) are set in Settings › AI, which opens above the card.
    private var customRow: some View {
        LabeledContent {
            Button("Set the base URL in Settings › AI") { window.selectSettings(.ai) }
                .buttonStyle(RowTextButtonStyle(formRow: true))
        } label: {
            Text("Server")
            SettingsHint("An OpenAI-compatible server and its model.")
        }
    }

    private func keyRow(_ provider: AIProvider) -> some View {
        LabeledContent {
            HStack(spacing: 8) {
                if !setup.keysLoaded {
                    DelayedSpinner(detail: "onboarding ai keys") { model.current == .ai }
                    Text("Reading the Keychain…")
                        .foregroundStyle(.secondary)
                } else if setup.keyStored[provider] == true {
                    Text(verbatim: "••• saved")
                        .foregroundStyle(.secondary)
                        .accessibilityLabel("API key saved")
                } else {
                    if keyBusy {
                        ProgressView().controlSize(.small)
                    }
                    SecureField("API key", text: $keyDraft, prompt: Text(verbatim: "sk-…"))
                        .textFieldStyle(.settings)
                        .frame(maxWidth: 240)
                        .labelsHidden()
                        .onSubmit { saveKey(provider) }
                    Button("Save") { saveKey(provider) }
                        .buttonStyle(RowTextButtonStyle(formRow: true))
                        .disabled(keyBusy || keyDraft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                }
            }
        } label: {
            Text("API key")
            switch keyResult {
            case .saved(let text):
                Label {
                    Text(verbatim: text).fixedSize(horizontal: false, vertical: true)
                } icon: {
                    IconImage("checkmark.circle.fill")
                }
                .font(.settingsCaption)
                .foregroundStyle(.green)
            case .failed(let text):
                // The provider's or the Keychain's words, never the key.
                Text(verbatim: text)
                    .font(.settingsCaption)
                    .foregroundStyle(.red)
                    .fixedSize(horizontal: false, vertical: true)
                    .textSelection(.enabled)
            case nil:
                SettingsHint(keyHint(provider))
            }
        }
    }

    private func keyHint(_ provider: AIProvider) -> String {
        if setup.keyStored[provider] == true {
            return "Kept in your login Keychain. Change or remove it in Settings › AI."
        }
        guard provider.requiresAPIKey else {
            return "Optional (many local servers take none). Kept in your login Keychain."
        }
        let host = URL(string: provider.defaultBaseURL)?.host() ?? provider.displayName
        return "From your \(provider.displayName) account. Kept in your login Keychain; only sent to \(host)."
    }

    /// Checks the key with the provider and saves it (`AISetup.saveKey`). The field is emptied at once, as in Settings
    /// › AI: the key stays in the view's state no longer than the save, a failed one included.
    private func saveKey(_ provider: AIProvider) {
        let draft = keyDraft
        guard !draft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty, !keyBusy else { return }
        keyDraft = ""
        keyBusy = true
        keyResult = nil
        Task {
            do {
                try await setup.saveKey(draft, for: provider)
                guard setup.provider == provider else { return keyBusy = false }
                keyResult = .saved(provider.requiresAPIKey ? "\(provider.displayName) accepted the key. It is saved."
                    : "The key is saved.")
            } catch {
                guard setup.provider == provider else { return keyBusy = false }
                keyResult = .failed("Not saved: \(String(describing: error))")
            }
            keyBusy = false
        }
    }
}
