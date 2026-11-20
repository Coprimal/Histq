// Settings › AI: the provider the AI buttons use (Generate Message, Explain, Suggest Resolution), its API key, model
// and, for a custom OpenAI-compatible server, its base URL, plus "Test connection". The key goes only into the login
// Keychain (account `ai.<provider>`, `AIKeys`), once the provider accepted it: Save lists the provider's models with
// it, and a key it refuses (another provider's, revoked, mistyped) is not saved and shows in a failure toast. The field
// is cleared once saved and the page then shows "••• saved", never the key. Nothing is sent to a provider until the
// user clicks Save, Test connection or an AI button.
import HistqCore
import SwiftUI
import os

/// The providers' API keys in `KeychainStore.shared`, account `ai.<provider raw value>`. Every call runs off the main
/// thread (a Keychain call can wait on a prompt). Keys are never logged or put in an error: only account names and
/// OSStatus codes.
enum AIKeys {
    private static let logger = Logger(subsystem: "com.math2it.histq", category: "keychain")

    static func account(_ provider: AIProvider) -> String { "ai.\(provider.rawValue)" }

    /// The key, nil when there is none. Throws `KeychainError` when the read failed.
    @concurrent
    static func key(for provider: AIProvider) async throws -> String? {
        do {
            return try KeychainStore.shared.string(account: account(provider))
        } catch {
            logger.error("read of \(account(provider), privacy: .public) failed: \(String(describing: error), privacy: .public)")
            throw error
        }
    }

    /// Which providers have a key, checked without reading the keys (Save never stores an empty one); a provider
    /// whose lookup failed is left out (unknown, so not set up).
    @concurrent
    static func presence() async -> [AIProvider: Bool] {
        var stored: [AIProvider: Bool] = [:]
        for provider in AIProvider.allCases {
            do {
                stored[provider] = try KeychainStore.shared.contains(account: account(provider))
            } catch {
                logger.error("lookup of \(account(provider), privacy: .public) failed: \(String(describing: error), privacy: .public)")
                continue
            }
        }
        return stored
    }

    @concurrent
    static func save(_ key: String, for provider: AIProvider) async throws {
        try KeychainStore.shared.setString(key, account: account(provider))
    }

    @concurrent
    static func delete(for provider: AIProvider) async throws {
        try KeychainStore.shared.delete(account: account(provider))
    }
}

/// The AI settings the hooks and the Settings page share: the active provider, each provider's model, the custom base
/// URL (all in `Preferences.defaults`) and whether each provider's key is in the Keychain (read off the main thread
/// once, then updated by Save and Remove). The hooks are enabled only while `isReady`.
@Observable
@MainActor
final class AISetup {
    static let shared = AISetup()

    /// The hooks' tooltip while the active provider is not set up.
    static let setUpHint = "Set up an AI provider in Settings › AI"

    private(set) var provider: AIProvider
    private(set) var models: [String: String]
    private(set) var customBaseURL: String
    /// Whether each provider's key is in the Keychain; a provider missing here is not read yet, or its read failed.
    private(set) var keyStored: [AIProvider: Bool] = [:]
    /// The first Keychain read has finished.
    private(set) var keysLoaded = false
    private var loadTask: Task<Void, Never>?

    private init() {
        let defaults = Preferences.defaults
        provider = defaults.string(forKey: PrefKey.aiProvider.rawValue).flatMap(AIProvider.init(rawValue:)) ?? .openAI
        models = defaults.dictionary(forKey: PrefKey.aiModels.rawValue) as? [String: String] ?? [:]
        customBaseURL = defaults.string(forKey: PrefKey.aiCustomBaseURL.rawValue) ?? ""
    }

    func setProvider(_ provider: AIProvider) {
        self.provider = provider
        Preferences.defaults.set(provider.rawValue, forKey: PrefKey.aiProvider.rawValue)
    }

    /// The model typed for `provider` (trimmed), else its default; empty for a custom server without one.
    func model(for provider: AIProvider) -> String {
        let typed = (models[provider.rawValue] ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        return typed.isEmpty ? provider.defaultModel : typed
    }

    /// The model field's text (empty = the default).
    func typedModel(for provider: AIProvider) -> String { models[provider.rawValue] ?? "" }

    func setTypedModel(_ text: String, for provider: AIProvider) {
        models[provider.rawValue] = text
        Preferences.defaults.set(models, forKey: PrefKey.aiModels.rawValue)
    }

    func setCustomBaseURL(_ text: String) {
        customBaseURL = text
        Preferences.defaults.set(text, forKey: PrefKey.aiCustomBaseURL.rawValue)
    }

    /// Why the custom base URL cannot be used; nil when it normalizes.
    var customURLError: AIEndpointError? {
        do {
            _ = try AIEndpoint.normalize(customBaseURL)
            return nil
        } catch {
            return error
        }
    }

    /// Why `provider` cannot be used yet; nil when it can. A built-in provider needs its key; a custom server needs a
    /// valid base URL (its key is optional, many local servers take none) and a model, which has no default there.
    func setupProblem(_ provider: AIProvider) -> String? {
        if provider == .custom {
            if let customURLError { return customURLError.description }
        } else if keyStored[provider] != true {
            return keysLoaded ? "Add an API key." : "Reading the Keychain…"
        }
        return model(for: provider).isEmpty ? "Enter a model." : nil
    }

    /// The active provider can be used: the AI buttons are enabled.
    var isReady: Bool { setupProblem(provider) == nil }

    /// Reads which providers have a key, once (off the main thread). The AI buttons call it when they appear.
    func loadKeysIfNeeded() {
        guard loadTask == nil else { return }
        reloadKeys()
    }

    /// Reads the keys' presence again (each select of the Settings page, so an item removed outside Histq shows).
    func reloadKeys() {
        loadTask?.cancel()
        loadTask = Task {
            #if DEBUG
            await AIStub.seedKeysIfNeeded()
            #endif
            let stored = await AIKeys.presence()
            guard !Task.isCancelled else { return }
            keyStored = stored
            keysLoaded = true
            #if DEBUG
            AIStub.log("keys read: \(provider.rawValue) ready \(isReady) problem \(setupProblem(provider) ?? "none")")
            #endif
        }
    }

    /// Checks and saves a key typed for `provider`. A built-in provider must accept it first: one model list (a GET
    /// to its own host, no diff); a custom server's key is optional and many such servers list no models, so only its
    /// characters are checked. Throws `AIClientError` (`invalidAPIKey` for spaces or other characters a key never has,
    /// the provider's refusal, or why it could not be reached: the key is not saved unchecked), `KeychainError` when
    /// the save failed. Nothing is saved when it throws.
    func saveKey(_ raw: String, for provider: AIProvider) async throws {
        let key = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard AIChatClient.isUsableAPIKey(key) else { throw AIClientError.invalidAPIKey }
        if provider.requiresAPIKey {
            _ = try await AIChatClient(provider: provider, apiKey: key, session: clientSession).listModels()
        }
        try await AIKeys.save(key, for: provider)
        keyStored[provider] = true
    }

    func removeKey(for provider: AIProvider) async throws {
        // Forgotten first: even if the delete fails, the buttons stop using the key the user asked to remove.
        keyStored[provider] = false
        try await AIKeys.delete(for: provider)
    }

    /// The AI clients' session: ephemeral with no URL cache, so a request that carries the key (the model list's GET)
    /// is never stored on disk, as `URLSession.shared`'s cache could.
    private nonisolated static let session: URLSession = {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.urlCache = nil
        return URLSession(configuration: configuration)
    }()

    /// `session`, or in a DEBUG `-HistqAIStub` run the stub's, which never reaches the network.
    private var clientSession: URLSession {
        #if DEBUG
        AIStub.isEnabled ? AIStub.session : Self.session
        #else
        Self.session
        #endif
    }

    /// The client of `provider` with its key (read off the main thread here, never kept), its fixed base URL or the
    /// custom one, over `clientSession`.
    func makeClient(for provider: AIProvider) async throws -> AIChatClient {
        let key = try await AIKeys.key(for: provider)
        return try AIChatClient(provider: provider, apiKey: key, customBaseURL: customBaseURL, session: clientSession)
    }
}

struct AISettings: View {
    @Environment(WindowModel.self) private var model
    @State private var keyDraft = ""
    @State private var keyBusy = false
    @State private var keyError: String?
    @State private var test: TestState = .idle
    @State private var testTask: Task<Void, Never>?
    @State private var modelList: ModelListState = .idle
    @State private var modelListTask: Task<Void, Never>?
    @AppStorage(PrefKey.aiShowFeatures.rawValue, store: Preferences.defaults)
    private var showFeatures = true
    @AppStorage(PrefKey.aiResponseLanguage.rawValue, store: Preferences.defaults)
    private var responseLanguage = "english"
    @AppStorage(PrefKey.aiCommitLanguage.rawValue, store: Preferences.defaults)
    private var commitLanguage = "english"
    @AppStorage(PrefKey.aiCommitSummaryOnly.rawValue, store: Preferences.defaults)
    private var commitSummaryOnly = false
    @AppStorage(PrefKey.aiCommitInstructions.rawValue, store: Preferences.defaults)
    private var commitInstructions = ""
    @AppStorage(PrefKey.aiExplainInstructions.rawValue, store: Preferences.defaults)
    private var explainInstructions = ""
    @AppStorage(PrefKey.aiConflictInstructions.rawValue, store: Preferences.defaults)
    private var conflictInstructions = ""
    @AppStorage(PrefKey.aiPullRequestInstructions.rawValue, store: Preferences.defaults)
    private var pullRequestInstructions = ""

    private enum TestState: Equatable {
        case idle
        case running
        case succeeded(String)
        case failed(String)
    }

    /// Load models: the provider's model ids, for this page's visit and provider only.
    private enum ModelListState: Equatable {
        case idle
        case loading
        case loaded([String])
        case failed(String)
    }

    private var setup: AISetup { .shared }

    var body: some View {
        SettingsPageGate(section: .ai, isLoaded: setup.keysLoaded) {
            SettingsGroup(nil) {
                SettingsSwitchRow(title: "Show AI features",
                                  hint: "Off hides every AI button. Nothing is sent until you click one.",
                                  isOn: $showFeatures)
            }
            languageGroup
            commitMessageGroup
            explanationsGroup
            conflictResolutionGroup
            pullRequestGroup
            providerGroup
            providerDetailsGroup
        } skeleton: {
            SettingsSkeletonGroup(rows: 1)
            SettingsSkeletonGroup(rows: 2)
            SettingsSkeletonGroup(rows: 2)
            SettingsSkeletonGroup(rows: 1)
            SettingsSkeletonGroup(rows: 1)
            SettingsSkeletonGroup(rows: 1)
            SettingsSkeletonGroup(rows: 2)
            SettingsSkeletonGroup(rows: 4)
        }
        .onChange(of: model.settingsToken, initial: true) {
            if model.settingsSection == .ai { setup.reloadKeys() }
        }
        .onChange(of: setup.provider) {
            cancelTest()
            resetModelList()
            keyDraft = ""
            keyError = nil
        }
        .onChange(of: setup.customBaseURL) {
            if setup.provider == .custom { resetModelList() }
        }
        .onDisappear {
            cancelTest()
            resetModelList()
            keyDraft = ""
        }
        #if DEBUG
        // `-HistqAI test` / `load-models` / `save-key` (stub runs only): clicks Test Connection or Load models once the
        // keys are read; `save-key` removes the seeded key, types the fake one and clicks Save.
        .task(id: setup.keysLoaded) {
            guard setup.keysLoaded else { return }
            if setup.isReady, AIStub.takeSeam("test") {
                runTest(setup.provider)
            } else if canLoadModels(setup.provider), AIStub.takeSeam("load-models") {
                loadModels(setup.provider)
            } else if setup.provider.requiresAPIKey, KeychainStore.shared.isInMemory, AIStub.takeSeam("save-key") {
                // The in-memory Keychain only: the seam never removes a real key.
                let provider = setup.provider
                try? await setup.removeKey(for: provider)
                keyDraft = AIStub.fakeKey
                saveKey(provider)
            }
        }
        #endif
    }

    // MARK: Provider

    private var providerGroup: some View {
        SettingsGroup("Provider", description: "Histq sends a diff, a commit or one conflict to the provider only when "
            + "you click Generate Message, Explain, Suggest Resolution or Test Connection. Nothing is saved, staged or "
            + "committed until you apply it.") {
            LabeledContent {
                CapsuleMenuPicker(label: "AI provider",
                                  selection: Binding(get: { setup.provider }, set: { setup.setProvider($0) }),
                                  title: Text(setup.provider.displayName)) {
                    ForEach(AIProvider.allCases, id: \.self) { provider in
                        Text(provider.displayName).tag(provider)
                    }
                }
            } label: {
                Text("Active provider")
                SettingsHint("The AI buttons in the commit box, the commit details and the conflict editor use it.")
            }
            .settingsSearchAnchor("Active provider")
            SettingsDivider()
            LabeledContent {
                if let problem = setup.setupProblem(setup.provider) {
                    Label(problem, systemImage: "exclamationmark.circle")
                        .foregroundStyle(.secondary)
                } else {
                    Label("Ready", systemImage: "checkmark.circle.fill")
                        .foregroundStyle(.green)
                }
            } label: {
                Text("Status")
                SettingsHint("\(setup.provider.displayName) with \(modelName)")
            }
        }
    }

    private var modelName: String {
        let name = setup.model(for: setup.provider)
        return name.isEmpty ? "no model yet" : name
    }

    // MARK: Provider details

    private var providerDetailsGroup: some View {
        let provider = setup.provider
        return SettingsGroup(provider.displayName) {
            if provider == .custom {
                baseURLRow
                SettingsDivider()
            }
            keyRow(provider)
            SettingsDivider()
            modelRow(provider)
            SettingsDivider()
            testRow(provider)
        }
    }

    private var baseURLRow: some View {
        LabeledContent {
            TextField("Base URL", text: Binding(get: { setup.customBaseURL }, set: { setup.setCustomBaseURL($0) }),
                      prompt: Text(verbatim: "https://example.com/v1"))
                .textFieldStyle(.settings)
                .frame(maxWidth: 280)
                .labelsHidden()
        } label: {
            Text("Base URL")
            if let error = setup.customURLError, !setup.customBaseURL.isEmpty {
                Text(error.description)
                    .font(.settingsCaption)
                    .foregroundStyle(.red)
                    .fixedSize(horizontal: false, vertical: true)
            } else {
                SettingsHint("An OpenAI-compatible server (chat completions). https, or http for this Mac only.")
            }
        }
        .settingsSearchAnchor("Base URL")
    }

    @ViewBuilder
    private func keyRow(_ provider: AIProvider) -> some View {
        LabeledContent {
            HStack(spacing: 8) {
                if keyBusy {
                    ProgressView().controlSize(.small)
                }
                if setup.keyStored[provider] == true {
                    Text(verbatim: "••• saved")
                        .foregroundStyle(.secondary)
                        .accessibilityLabel("API key saved")
                    Button("Remove") { removeKey(provider) }
                        .buttonStyle(RowTextButtonStyle(formRow: true))
                        .disabled(keyBusy)
                } else {
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
            if let keyError {
                Text(keyError)
                    .font(.settingsCaption)
                    .foregroundStyle(.red)
                    .fixedSize(horizontal: false, vertical: true)
            } else {
                SettingsHint(provider.requiresAPIKey ? "Kept in your login Keychain; only sent to \(hostName(provider))."
                    : "Optional (many local servers take none). Kept in your login Keychain.")
            }
        }
        .settingsSearchAnchor("API key")
    }

    private func hostName(_ provider: AIProvider) -> String {
        URL(string: provider.defaultBaseURL)?.host() ?? provider.displayName
    }

    private func modelRow(_ provider: AIProvider) -> some View {
        LabeledContent {
            HStack(spacing: 8) {
                TextField("Model", text: Binding(get: { setup.typedModel(for: provider) },
                                                 set: { setup.setTypedModel($0, for: provider) }),
                          prompt: Text(verbatim: provider.defaultModel.isEmpty ? "model id" : provider.defaultModel))
                    .textFieldStyle(.settings)
                    .frame(maxWidth: 240)
                    .labelsHidden()
                if case .loaded(let ids) = modelList, !ids.isEmpty {
                    loadedModelsPicker(ids, provider: provider)
                } else if !provider.requiresAPIKey || setup.keyStored[provider] == true {
                    // The spinner sits over the hidden title, so the row keeps its width while it loads.
                    Button { loadModels(provider) } label: {
                        Text("Load models")
                            .opacity(modelList == .loading ? 0 : 1)
                            .overlay {
                                if modelList == .loading { DelayedSpinner(detail: "ai models") }
                            }
                    }
                    .buttonStyle(RowTextButtonStyle(formRow: true))
                    .disabled(modelList == .loading || !canLoadModels(provider))
                    .help(canLoadModels(provider) ? "Lists the models of \(provider.displayName)"
                        : setup.customURLError?.description ?? "")
                }
            }
        } label: {
            Text("Model")
            switch modelList {
            case .failed(let text):
                Text(text)
                    .font(.settingsCaption)
                    .foregroundStyle(.red)
                    .lineLimit(2)
                    .fixedSize(horizontal: false, vertical: true)
                    .textSelection(.enabled)
            case .loaded(let ids) where ids.isEmpty:
                SettingsHint("No models listed; type the model id.")
            default:
                SettingsHint(provider.defaultModel.isEmpty ? "The model id your server serves."
                    : "Empty uses \(provider.defaultModel). Any model id of the provider works.")
            }
        }
        .settingsSearchAnchor("Model")
    }

    /// "N models": picking one fills the model field. The check marks the model in use.
    private func loadedModelsPicker(_ ids: [String], provider: AIProvider) -> some View {
        CapsuleMenuPicker(label: "Loaded models",
                          selection: Binding(get: { setup.model(for: provider) },
                                             set: { setup.setTypedModel($0, for: provider) }),
                          title: Text(ids.count == 1 ? "1 model" : "\(ids.count) models")) {
            ForEach(ids, id: \.self) { id in
                Text(verbatim: id).tag(id)
            }
        }
    }

    /// Load models can run: a built-in provider has its key saved; a custom server has a valid base URL (its key is
    /// optional and it may have no model yet).
    private func canLoadModels(_ provider: AIProvider) -> Bool {
        provider.requiresAPIKey ? setup.keyStored[provider] == true : setup.customURLError == nil
    }

    private func testRow(_ provider: AIProvider) -> some View {
        LabeledContent {
            HStack(spacing: 8) {
                if test == .running {
                    ProgressView().controlSize(.small)
                    Button("Cancel", action: cancelTest)
                        .buttonStyle(RowTextButtonStyle(formRow: true))
                } else {
                    Button("Test Connection") { runTest(provider) }
                        .buttonStyle(RowTextButtonStyle(formRow: true))
                        .disabled(setup.setupProblem(provider) != nil)
                        .help(setup.setupProblem(provider) ?? "Sends a one-line prompt to \(provider.displayName)")
                }
            }
        } label: {
            Text("Test connection")
            switch test {
            case .idle, .running:
                SettingsHint("Sends a one-line prompt and waits for the first words of the answer.")
            case .succeeded(let text):
                Label(text, systemImage: "checkmark.circle.fill")
                    .font(.settingsCaption)
                    .foregroundStyle(.green)
                    .fixedSize(horizontal: false, vertical: true)
            case .failed(let text):
                Text(text)
                    .font(.settingsCaption)
                    .foregroundStyle(.red)
                    .fixedSize(horizontal: false, vertical: true)
                    .textSelection(.enabled)
            }
        }
        .settingsSearchAnchor("Test connection")
    }

    // MARK: Language

    private var languageGroup: some View {
        SettingsGroup("Language") {
            LabeledContent {
                languagePicker("Explanations language", selection: $responseLanguage)
            } label: {
                Text("Explanations")
                SettingsHint("Explain, for a commit and for your changes.")
            }
            .settingsSearchAnchor("Explanations")
            SettingsDivider()
            LabeledContent {
                languagePicker("Commit messages language", selection: $commitLanguage)
            } label: {
                Text("Commit messages")
                SettingsHint("Generate Message. Suggest Resolution keeps the code as it is.")
            }
            .settingsSearchAnchor("Commit messages")
        }
    }

    // MARK: Commit messages

    private var commitMessageGroup: some View {
        SettingsGroup("Commit messages") {
            SettingsSwitchRow(title: "Summary only",
                              hint: "Generate Message writes the summary line only and keeps your description.",
                              isOn: $commitSummaryOnly)
            SettingsDivider()
            instructionsEditor($commitInstructions,
                               hint: "Added to Histq's prompt for Generate Message and followed over its default "
                                   + "style. Sent to the provider with the staged diff.",
                               placeholder: "Use Conventional Commits: type(scope): summary")
        }
    }

    // MARK: Explanations, conflict resolution and pull requests

    private var explanationsGroup: some View {
        SettingsGroup("Explanations") {
            instructionsEditor($explainInstructions,
                               hint: "Added to Histq's prompt for Explain, for a commit and for your changes. "
                                   + "Sent to the provider with the diff.",
                               placeholder: "Point out changes to the public API first")
        }
    }

    private var conflictResolutionGroup: some View {
        SettingsGroup("Conflict resolution") {
            instructionsEditor($conflictInstructions,
                               hint: "Added to Histq's prompt for Suggest Resolution. "
                                   + "Sent to the provider with the conflict region.",
                               placeholder: "Prefer the current branch's naming")
        }
    }

    private var pullRequestGroup: some View {
        SettingsGroup("Pull requests") {
            instructionsEditor($pullRequestInstructions,
                               hint: "Added to Histq's prompt for Generate in Create Pull Request. "
                                   + "Sent to the provider with the branch's commits, diff and template.",
                               placeholder: "Keep the description to a few short bullet points")
        }
    }

    /// A "Custom instructions" box (one per AI action) with Reset to Default, which empties it (Histq's prompt alone).
    private func instructionsEditor(_ text: Binding<String>, hint: String, placeholder: String) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(alignment: .firstTextBaseline) {
                VStack(alignment: .leading, spacing: 2) {
                    Text("Custom instructions")
                    SettingsHint(hint)
                }
                Spacer()
                Button("Reset to Default") { text.wrappedValue = "" }
                    .buttonStyle(RowTextButtonStyle(formRow: true))
                    .disabled(text.wrappedValue.isEmpty)
            }
            TextEditor(text: text)
                .font(.body)
                .settingsTextEditor()
                .frame(height: 88)
                .overlay(alignment: .topLeading) {
                    if text.wrappedValue.isEmpty {
                        Text(verbatim: placeholder)
                            .foregroundStyle(.tertiary)
                            .padding(.horizontal, 11)
                            .padding(.vertical, 8)
                            .allowsHitTesting(false)
                    }
                }
                .accessibilityLabel("Custom instructions")
        }
        .settingsSearchAnchor("Custom instructions")
    }

    /// The fixed language list; an unknown stored value shows as English.
    private func languagePicker(_ label: String, selection: Binding<String>) -> some View {
        let current = AIResponseLanguage(rawValue: selection.wrappedValue) ?? .english
        return CapsuleMenuPicker(label: label,
                                 selection: Binding(get: { current }, set: { selection.wrappedValue = $0.rawValue }),
                                 title: Text(current.displayName)) {
            ForEach(AIResponseLanguage.allCases, id: \.self) { language in
                Text(language.displayName).tag(language)
            }
        }
    }

    // MARK: Actions

    private func saveKey(_ provider: AIProvider) {
        let draft = keyDraft
        guard !draft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty, !keyBusy else { return }
        // The key stays in the page's state no longer than the save, a failed one included.
        keyDraft = ""
        keyBusy = true
        keyError = nil
        Task {
            do {
                try await setup.saveKey(draft, for: provider)
                #if DEBUG
                AIStub.log("key saved \(provider.rawValue)")
                #endif
            } catch {
                // Only in its toast, not on the row too.
                model.showToast(OperationToast(kind: .failure, title: "\(provider.displayName) API key not saved",
                                               detail: String(describing: error)))
                #if DEBUG
                AIStub.log("key not saved \(provider.rawValue): \(String(describing: error))")
                #endif
            }
            keyBusy = false
        }
    }

    private func removeKey(_ provider: AIProvider) {
        cancelTest()
        resetModelList()
        keyBusy = true
        keyError = nil
        Task {
            do {
                try await setup.removeKey(for: provider)
            } catch {
                keyError = "The key could not be removed: \(String(describing: error))"
            }
            keyBusy = false
        }
    }

    /// A tiny prompt; success needs at least one text piece, since a 200 answer that is not a stream ends with no text
    /// and no error.
    private func runTest(_ provider: AIProvider) {
        testTask?.cancel()
        test = .running
        let modelName = setup.model(for: provider)
        testTask = Task {
            do {
                let client = try await setup.makeClient(for: provider)
                let request = AIChatRequest(
                    model: modelName, system: "You are a connection check. Answer briefly.",
                    messages: [AIChatMessage(role: .user, text: "Reply with the single word OK.")], maxTokens: 16)
                var pieces = 0
                for try await piece in client.stream(request) where !piece.isEmpty {
                    pieces += 1
                    // The first words prove the connection; the rest is not needed.
                    if pieces >= 4 { break }
                }
                try Task.checkCancellation()
                guard pieces > 0 else {
                    test = .failed("\(provider.displayName) answered without any text. Check the model and the base URL.")
                    return
                }
                test = .succeeded("\(provider.displayName) answered with \(modelName).")
                #if DEBUG
                AIStub.log("test-connection ok \(provider.rawValue) pieces \(pieces)")
                #endif
            } catch {
                guard !(error is CancellationError), !Task.isCancelled else { return }
                test = .failed(String(describing: error))
                #if DEBUG
                AIStub.log("test-connection failed \(provider.rawValue): \(String(describing: error))")
                #endif
            }
        }
    }

    private func cancelTest() {
        testTask?.cancel()
        testTask = nil
        if test == .running { test = .idle }
    }

    /// Lists `provider`'s models (one GET with its key); the errors are already without the key.
    private func loadModels(_ provider: AIProvider) {
        modelListTask?.cancel()
        modelList = .loading
        modelListTask = Task {
            do {
                let ids = try await setup.makeClient(for: provider).listModels()
                try Task.checkCancellation()
                modelList = .loaded(ids)
                #if DEBUG
                AIStub.log("models loaded \(provider.rawValue) \(ids.count): \(ids.joined(separator: ","))")
                #endif
            } catch {
                guard !(error is CancellationError), !Task.isCancelled else { return }
                modelList = .failed(String(describing: error))
                #if DEBUG
                AIStub.log("models failed \(provider.rawValue): \(String(describing: error))")
                #endif
            }
        }
    }

    private func resetModelList() {
        modelListTask?.cancel()
        modelListTask = nil
        modelList = .idle
    }
}
