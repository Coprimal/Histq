// One repo tab's AI chat (structure from Dblore's `AIAssistantViewModel`): the conversation shown, the draft, the
// turn being streamed and the saved chats for the history list. A click (Send, Explain) appends its entries in its
// own frame; the hidden context is built off the main actor, then the answer streams into the assistant entry,
// shown at most every 50 ms as `AIRun` does. Attached references (chips) are only kept until a send, an Explain or a
// quick action resolves them off the main actor; the entry keeps them, and their resolved text as its hidden context. Every turn carries a generation token: Stop, New Chat, opening or
// deleting a chat and a new Explain bump it, so an old stream's text never lands anywhere. Switching while a turn
// runs stops it first and saves its partial answer in its own conversation. The store is only called from tasks,
// one after another in call order, and its errors are logged, never shown in the chat.
//
// A turn runs through `AIToolLoop`: with Settings › AI's "Let the chat read the repository" on, the model may call
// the read-only git tools (`AIGitTools`); each call becomes a tool entry before the answer, saved with its output cut
// to 4 KB and replayed on later turns as data blocks (`AIChatHistory`), never re-run. Only the last step's text is the
// answer: a tool call clears what its step wrote (in the text protocol, the ```tool block itself).
import Foundation
import HistqCore
import os

@Observable
@MainActor
final class AIChatModel {
    /// A saved chat as the history list shows it.
    struct Summary: Identifiable, Equatable {
        let id: UUID
        let title: String
        let updatedAt: Date
    }

    /// A turn's hidden context and the `AIIgnore.digest` of the `.aiignore` it was filtered with.
    typealias Context = (text: String, ignoreDigest: String)
    /// A git tool call's answer, its tool row count (`AIGitToolOutput.summary`) and the `AIIgnore.digest` of the
    /// `.aiignore` it was filtered with (nil when none was read).
    typealias ToolRun = (result: AIToolResult, summary: String?, ignoreDigest: String?)

    private(set) var entries: [AIChatEntry] = []
    var draft = ""
    /// The references attached to the next message (chips above the composer); nothing is read until it is sent.
    private(set) var attachments: [AIChatReference] = []
    private(set) var isGenerating = false
    var isExpanded = false
    /// The saved chats, newest first (loaded by `loadConversations()`, refreshed by each save or delete).
    private(set) var conversations: [Summary] = []
    /// The first load of `conversations` finished (the history list shows a placeholder until then).
    private(set) var conversationsLoaded = false
    private(set) var conversationID = UUID()

    /// Bumped by every stop or switch: a turn whose token is not the current one changes nothing.
    @ObservationIgnored private(set) var generation = 0

    private static let logger = Logger(subsystem: "com.math2it.histq", category: "ai-chat")

    private let store: AIConversationStore
    /// The system prompt of a turn, read at its click (Settings › AI's language and instructions as they are then).
    private let system: @MainActor () -> String
    /// The worktree's current `AIIgnore.digest`, read at each send (throws when `.aiignore` can't be read, so the turn
    /// sends nothing): a saved hidden context filtered with other rules is never sent again.
    private let ignoreDigest: @Sendable () async throws -> String?
    /// The hidden context of `references` (data blocks), with the digest of the `.aiignore` it was filtered with;
    /// throws when nothing may be sent. Called at send, off the main actor.
    private let resolve: @Sendable ([AIChatReference]) async throws -> Context
    /// Runs one git tool call off the main actor (`AIGitTools.run` with the read environment and the `.aiignore` read
    /// for that call).
    private let runTool: @Sendable (AIToolCall) async -> ToolRun
    /// The running turn's tool rows and digests by call id, from `runTool` until the loop reports the result.
    @ObservationIgnored private var toolRuns: [String: ToolRun] = [:]
    /// The saved chats by id, so opening one needs no read.
    @ObservationIgnored private var saved: [UUID: AIConversation] = [:]
    /// Not observed, so `deinit` (nonisolated) can cancel it.
    @ObservationIgnored private var task: Task<Void, Never>?
    /// The last store call: each new one waits for it, so saves and deletes land in call order.
    @ObservationIgnored private var storeTask: Task<Void, Never>?
    /// The running turn's whole reply and its entry: the throttle may hold back the end, which a stop, an error or
    /// the end of the stream writes into the entry.
    @ObservationIgnored private var reply = ""
    @ObservationIgnored private var replyID: UUID?
    /// When the streamed text was last written into the entry (the throttle).
    @ObservationIgnored private var shown = ContinuousClock.now
    /// The running turn's timing name (`ai <logName>`) and whether its placeholder and content were logged.
    @ObservationIgnored private var turnDetail = ""
    @ObservationIgnored private var placeholderLogged = false
    @ObservationIgnored private var contentLogged = false

    init(
        storeURL: URL, system: @escaping @MainActor () -> String,
        ignoreDigest: @escaping @Sendable () async throws -> String?,
        resolve: @escaping @Sendable ([AIChatReference]) async throws -> Context,
        runTool: @escaping @Sendable (AIToolCall) async -> ToolRun
    ) {
        store = AIConversationStore(url: storeURL)
        self.system = system
        self.ignoreDigest = ignoreDigest
        self.resolve = resolve
        self.runTool = runTool
    }

    deinit {
        // The task holds only a weak reference: without this, a chat dropped with its tab would still send.
        task?.cancel()
    }

    // MARK: Actions

    /// The quick actions the attachments offer (none without one).
    var quickActions: [AIQuickAction] { AIQuickAction.actions(for: attachments) }

    /// Sends the draft as a follow-up in the current conversation, with the attachments (resolved off the main actor).
    func send() {
        let text = draft.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !isGenerating, !text.isEmpty else { return }
        draft = ""
        let references = attachments
        attachments = []
        let user = AIChatEntry(role: .user, text: text, references: references.isEmpty ? nil : references)
        let assistant = AIChatEntry(role: .assistant, text: "")
        entries += [user, assistant]
        var context: (@Sendable () async throws -> Context)?
        if !references.isEmpty {
            let resolve = resolve
            context = { try await resolve(references) }
        }
        startTurn(userID: user.id, assistantID: assistant.id, logName: "chat-send", context: context)
    }

    /// Add to AI Chat: `references` become chips of the next message (each once); nothing is read or sent.
    func attach(_ references: [AIChatReference]) {
        for reference in references where !attachments.contains(reference) {
            attachments.append(reference)
        }
    }

    /// A chip's x: `reference` is no longer attached.
    func detach(_ reference: AIChatReference) {
        attachments.removeAll { $0 == reference }
    }

    /// Explain on references: a new conversation that sends at once, the Explain rules before the resolved blocks.
    func explain(_ references: [AIChatReference]) {
        guard !references.isEmpty else { return }
        let resolve = resolve
        startExplain(
            label: Self.explainLabel(references), modelText: "Explain the changes in the data blocks.",
            logName: "explain-refs", references: references
        ) {
            let resolved = try await resolve(references)
            return (AIPrompts.chatExplainReferencesContext(resolved.text), resolved.ignoreDigest)
        }
    }

    /// A quick action chip: a new conversation that sends at once with the action's label as the user's line, its
    /// fixed instruction for the model and the attachments (which it uses up) as the hidden context.
    func runQuickAction(_ action: AIQuickAction) {
        let references = attachments
        guard !references.isEmpty else { return }
        attachments = []
        let resolve = resolve
        startExplain(
            label: action.label, modelText: action.instruction, logName: "quick-\(action.rawValue)",
            references: references
        ) { try await resolve(references) }
    }

    /// The user's line of an Explain on references (UI only).
    private static func explainLabel(_ references: [AIChatReference]) -> String {
        guard references.count == 1, let reference = references.first else {
            return "Explain these \(references.count) references"
        }
        return switch reference {
        case .commits(let hashes) where hashes.count > 1: "Explain these \(hashes.count) commits"
        case .commits(let hashes): "Explain commit \(hashes.first?.prefix(7) ?? "")"
        case .wip(let staged): staged ? "Explain staged changes" : "Explain unstaged changes"
        case .branch, .fileInCommit, .pullRequest: "Explain \(reference.label)"
        }
    }

    /// An Explain (or any action that starts its own chat): a new conversation with `label` shown as the user's line
    /// and the empty answer, in this call. `modelText` is the fixed sentence the model gets in place of `label`;
    /// `context` builds the hidden context (data blocks) off the main actor, with the digest of the `.aiignore` it
    /// was filtered with, and throws when nothing may be sent; `references` are kept on the user entry.
    /// `logName` names the turn in the timing log (`ai <logName>`).
    func startExplain(
        label: String, modelText: String, logName: String, references: [AIChatReference]? = nil,
        context: @escaping @Sendable () async throws -> Context
    ) {
        leaveConversation()
        conversationID = UUID()
        let user = AIChatEntry(role: .user, text: label, modelText: modelText, references: references)
        let assistant = AIChatEntry(role: .assistant, text: "")
        entries = [user, assistant]
        startTurn(userID: user.id, assistantID: assistant.id, logName: logName, context: context)
    }

    /// Continue in Chat: a new conversation holding an earlier one-turn job, in this call, and saved; nothing is sent
    /// until the user follows up. `label` is the user's line (UI only), `modelText` the fixed sentence the model gets
    /// in its place, `context` the job's data blocks (`AIPrompts.chatSeedContext`) and `answer` the job's answer, as
    /// the assistant's entry. `ignoreDigest` is the digest of the `.aiignore` the job's prompt was filtered with
    /// (`AIRun.ignoreDigest`), never the current one: a `.aiignore` changed since the job omits the context from every
    /// request, and nil (unknown) always does (never sent unchecked).
    func seed(label: String, modelText: String, context: String, answer: String, ignoreDigest: String?) {
        leaveConversation()
        conversationID = UUID()
        let user = AIChatEntry(
            role: .user, text: label, modelText: modelText, hiddenContext: context, ignoreDigest: ignoreDigest)
        entries = [user, AIChatEntry(role: .assistant, text: answer)]
        save()
    }

    /// Stops the turn (its partial answer stays) and saves the conversation.
    func stop() {
        guard isGenerating else { return }
        endTurn()
        save()
    }

    /// An empty conversation; the current one is already saved (or saved here when a turn was running).
    func newChat() {
        leaveConversation()
        entries = []
        conversationID = UUID()
    }

    /// Shows the saved chat `id` (from `conversations`).
    func open(id: UUID) {
        guard id != conversationID, let conversation = saved[id] else { return }
        leaveConversation()
        entries = conversation.entries
        conversationID = id
    }

    /// Deletes the saved chat `id`; the current one is replaced by an empty conversation.
    func delete(id: UUID) {
        if id == conversationID {
            // Its partial answer is not saved: the chat is deleted anyway.
            if isGenerating { endTurn() }
            entries = []
            conversationID = UUID()
        }
        conversations.removeAll { $0.id == id }
        saved[id] = nil
        enqueue(loads: false) { try await $0.delete(id: id) }
    }

    /// Reads the saved chats (the history list opened).
    func loadConversations() {
        enqueue(loads: true) { try await $0.load() }
    }

    // MARK: Turn

    private func startTurn(
        userID: UUID, assistantID: UUID, logName: String, context: (@Sendable () async throws -> Context)?
    ) {
        let setup = AISetup.shared
        let provider = setup.provider
        let model = setup.model(for: provider)
        let systemPrompt = system()
        let ignoreDigest = ignoreDigest
        let runTool = runTool
        // Switch off: no tools offered and one plain step (native, so no tools section is added to the prompt).
        let loop = Preferences.defaults.bool(forKey: PrefKey.aiChatReadsRepository.rawValue)
            ? AIToolLoop(tools: AIGitTools.specs, nativeTools: provider.supportsNativeTools)
            : AIToolLoop(tools: [], nativeTools: true, maxSteps: 1)
        generation += 1
        let token = generation
        isGenerating = true
        reply = ""
        replyID = assistantID
        toolRuns = [:]
        turnDetail = "ai \(logName)"
        placeholderLogged = false
        contentLogged = false
        UITiming.select(turnDetail)
        task = Task { [weak self] in
            do {
                let hidden = try await context?()
                // Read after the context, so a `.aiignore` changed meanwhile omits that context too.
                let digest = try await ignoreDigest()
                try Task.checkCancellation()
                guard let request = self?.request(
                    token: token, userID: userID, hidden: hidden, ignoreDigest: digest, model: model,
                    system: systemPrompt
                ) else { return }
                let client = try await AISetup.shared.makeClient(for: provider)
                // The last point before anything leaves the Mac: a turn stopped meanwhile sends nothing.
                guard self?.generation == token, !Task.isCancelled else { return }
                let outcome = try await loop.run(
                    request: request,
                    step: { [weak self] request in
                        // Between steps: a turn stopped meanwhile sends nothing more.
                        guard await self?.clearReply(token: token) == true else { throw CancellationError() }
                        return client.events(request)
                    },
                    runTool: { [weak self] call in
                        let run = await runTool(call)
                        await self?.keepToolRun(run, for: call.id, token: token)
                        return run.result
                    },
                    onEvent: { [weak self] event in await self?.handle(event, token: token, logName: logName) })
                try Task.checkCancellation()
                self?.finishTurn(token: token, answer: outcome.text)
            } catch {
                guard !Task.isCancelled else { return }
                // A context builder that gave up (its session gone) ends the turn without an error entry.
                if error is CancellationError {
                    self?.finishTurn(token: token)
                } else {
                    self?.failTurn(token: token, error: error)
                }
            }
        }
    }

    /// The turn's request: the hidden context and its digest are kept on the user entry (saved and replayed), then
    /// the history is taken from the entries (the empty answer is never in it), every context whose digest is not
    /// `ignoreDigest` omitted. Nil when the turn was stopped meanwhile.
    private func request(
        token: Int, userID: UUID, hidden: Context?, ignoreDigest: String?, model: String, system: String
    ) -> AIChatRequest? {
        guard generation == token else { return nil }
        if let hidden, let index = entries.firstIndex(where: { $0.id == userID }) {
            entries[index].hiddenContext = hidden.text
            entries[index].ignoreDigest = hidden.ignoreDigest
        }
        let messages = AIChatHistory.messages(
            from: entries, budget: 4 * AIPrompts.diffBudget, ignoreDigest: ignoreDigest)
        return AIChatRequest(model: model, system: system, messages: messages)
    }

    // MARK: Loop events

    private func handle(_ event: AIToolLoopEvent, token: Int, logName: String) {
        guard generation == token, let replyID else { return }
        switch event {
        case .text(let piece):
            reply += piece
            // At once while nothing shows (the first words' timing), then at most ~20 times a second.
            guard text(of: replyID).isEmpty || ContinuousClock.now - shown >= .milliseconds(50) else { return }
            flushReply()
            shown = .now
            #if DEBUG
            if AIStub.takeChatOption("cancel") {
                AIStub.log("cancel \(logName) after reply chars \(reply.count)")
                stop()
            }
            #endif
        case .toolCall:
            // The step's text is not the answer (in the text protocol it holds the ```tool block).
            _ = clearReply(token: token)
        case .toolResult(let call, let result):
            let run = toolRuns.removeValue(forKey: call.id)
            let summary = result.isError ? nil : run?.summary
            let row = result.isError ? "\(call.name) failed" : "Ran \(call.name)" + (summary.map { " · \($0)" } ?? "")
            let entry = AIChatEntry.tool(
                call, output: result.content, text: row, ignoreDigest: run?.ignoreDigest, isError: result.isError)
            entries.insert(entry, at: entries.firstIndex { $0.id == replyID } ?? entries.endIndex)
        case .stepLimit, .finished:
            break
        }
    }

    /// A new step or a tool call: what the step wrote so far is dropped from the answer. False when the turn ended.
    private func clearReply(token: Int) -> Bool {
        guard generation == token else { return false }
        reply = ""
        if let replyID, let index = entries.firstIndex(where: { $0.id == replyID }) { entries[index].text = "" }
        return true
    }

    private func keepToolRun(_ run: ToolRun, for id: String, token: Int) {
        guard generation == token else { return }
        toolRuns[id] = run
    }

    // MARK: Turn end

    /// The loop's answer (the last step's text, or the step-limit note) replaces what streamed.
    private func finishTurn(token: Int, answer: String? = nil) {
        guard generation == token else { return }
        if let answer {
            _ = clearReply(token: token)
            reply = answer
        }
        endTurn()
        logContent()
        save()
        #if DEBUG
        AIStub.log("chat finished \(turnDetail) chars \(reply.count)")
        if let text = AIStub.takeChatSend() {
            AIStub.log("chat-send \(AIStub.quoted(text))")
            draft = text
            send()
        }
        #endif
    }

    /// The partial answer stays; the error shows in its own entry after it (an answer still empty is removed).
    private func failTurn(token: Int, error: any Error) {
        guard generation == token else { return }
        endTurn()
        entries.append(AIChatEntry(role: .assistant, text: String(describing: error), isError: true))
        logContent()
        save()
        #if DEBUG
        AIStub.log("chat failed \(turnDetail): \(error)")
        #endif
    }

    /// Cancels the turn, bumps the token, keeps what came of the answer and drops an answer still empty.
    private func endTurn() {
        task?.cancel()
        task = nil
        generation += 1
        flushReply()
        replyID = nil
        isGenerating = false
        entries.removeAll { $0.role == .assistant && !$0.isError && $0.text.allSatisfy(\.isWhitespace) }
    }

    /// Before a new or another conversation: a running turn stops and is saved in its own conversation.
    private func leaveConversation() {
        if isGenerating { stop() }
    }

    private func flushReply() {
        guard let replyID, !reply.isEmpty, let index = entries.firstIndex(where: { $0.id == replyID }) else { return }
        entries[index].text = reply
        logContent()
    }

    private func text(of id: UUID) -> String {
        entries.first { $0.id == id }?.text ?? ""
    }

    /// The turn's "Thinking…" row showed: logged once per turn, and not once its content showed.
    func logPlaceholder() {
        guard !placeholderLogged, !contentLogged, !turnDetail.isEmpty else { return }
        placeholderLogged = true
        UITiming.placeholder(turnDetail)
    }

    /// The first words (or the turn's answer or error) showed: logged once per turn, never for a stop.
    private func logContent() {
        guard !contentLogged, !turnDetail.isEmpty else { return }
        contentLogged = true
        UITiming.content(turnDetail)
    }

    // MARK: Store

    /// Saves the conversation as it is now (nothing without a user entry).
    private func save() {
        guard entries.contains(where: { $0.role == .user }) else { return }
        let conversation = AIConversation(id: conversationID, entries: entries)
        enqueue(loads: false) { try await $0.upsert(conversation) }
    }

    /// Runs `work` after the previous store call, off the main actor (the store's actor), then shows the list it
    /// returns. Failures are logged; `loads` marks the list loaded even then (so the placeholder never stays).
    private func enqueue(
        loads: Bool, _ work: @escaping @Sendable (AIConversationStore) async throws -> [AIConversation]
    ) {
        let previous = storeTask
        let store = store
        storeTask = Task { [weak self] in
            await previous?.value
            do {
                let list = try await work(store)
                self?.show(list)
            } catch {
                let action = loads ? "load" : "save"
                Self.logger.error("Chats \(action, privacy: .public) failed: \(String(describing: error))")
                if loads { self?.conversationsLoaded = true }
            }
        }
    }

    private func show(_ list: [AIConversation]) {
        conversations = list.map { Summary(id: $0.id, title: $0.title, updatedAt: $0.updatedAt) }
        saved = Dictionary(list.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
        conversationsLoaded = true
    }
}
