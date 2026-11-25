// One repo tab's AI chat (structure from Dblore's `AIAssistantViewModel`): the conversation shown, the draft, the
// turn being streamed and the saved chats for the history list. A click (Send, Explain) appends its entries in its
// own frame; the hidden context is built off the main actor, then the answer streams into the assistant entry,
// shown at most every 50 ms as `AIRun` does. Every turn carries a generation token: Stop, New Chat, opening or
// deleting a chat and a new Explain bump it, so an old stream's text never lands anywhere. Switching while a turn
// runs stops it first and saves its partial answer in its own conversation. The store is only called from tasks,
// one after another in call order, and its errors are logged, never shown in the chat.
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

    private(set) var entries: [AIChatEntry] = []
    var draft = ""
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
    /// The worktree's current `AIIgnore.digest`, read at each send (nil when `.aiignore` can't be read): a saved
    /// hidden context filtered with other rules is never sent again.
    private let ignoreDigest: @Sendable () async -> String?
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
    /// The running turn's timing name (`ai <logName>`) and whether its content was logged.
    @ObservationIgnored private var turnDetail = ""
    @ObservationIgnored private var contentLogged = false

    init(
        storeURL: URL, system: @escaping @MainActor () -> String,
        ignoreDigest: @escaping @Sendable () async -> String?
    ) {
        store = AIConversationStore(url: storeURL)
        self.system = system
        self.ignoreDigest = ignoreDigest
    }

    deinit {
        // The task holds only a weak reference: without this, a chat dropped with its tab would still send.
        task?.cancel()
    }

    // MARK: Actions

    /// Sends the draft as a follow-up in the current conversation.
    func send() {
        let text = draft.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !isGenerating, !text.isEmpty else { return }
        draft = ""
        let user = AIChatEntry(role: .user, text: text)
        let assistant = AIChatEntry(role: .assistant, text: "")
        entries += [user, assistant]
        startTurn(userID: user.id, assistantID: assistant.id, logName: "chat-send", context: nil)
    }

    /// An Explain (or any action that starts its own chat): a new conversation with `label` shown as the user's line
    /// and the empty answer, in this call. `modelText` is the fixed sentence the model gets in place of `label`;
    /// `context` builds the hidden context (data blocks) off the main actor, with the digest of the `.aiignore` it
    /// was filtered with, and throws when nothing may be sent;
    /// `logName` names the turn in the timing log (`ai <logName>`).
    func startExplain(
        label: String, modelText: String, logName: String, context: @escaping @Sendable () async throws -> Context
    ) {
        leaveConversation()
        conversationID = UUID()
        let user = AIChatEntry(role: .user, text: label, modelText: modelText)
        let assistant = AIChatEntry(role: .assistant, text: "")
        entries = [user, assistant]
        startTurn(userID: user.id, assistantID: assistant.id, logName: logName, context: context)
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
        generation += 1
        let token = generation
        isGenerating = true
        reply = ""
        replyID = assistantID
        turnDetail = "ai \(logName)"
        contentLogged = false
        UITiming.select(turnDetail)
        task = Task { [weak self] in
            do {
                let hidden = try await context?()
                // Read after the context, so a `.aiignore` changed meanwhile omits that context too.
                let digest = await ignoreDigest()
                try Task.checkCancellation()
                guard let request = self?.request(
                    token: token, userID: userID, hidden: hidden, ignoreDigest: digest, model: model,
                    system: systemPrompt
                ) else { return }
                let client = try await AISetup.shared.makeClient(for: provider)
                // The last point before anything leaves the Mac: a turn stopped meanwhile sends nothing.
                guard self?.generation == token, !Task.isCancelled else { return }
                var shown = ContinuousClock.now
                for try await piece in client.stream(request) {
                    guard let self, generation == token else { return }
                    reply += piece
                    // At once while nothing shows (the first words' timing), then at most ~20 times a second.
                    guard text(of: assistantID).isEmpty || ContinuousClock.now - shown >= .milliseconds(50) else {
                        continue
                    }
                    flushReply()
                    shown = .now
                    #if DEBUG
                    if AIStub.takeChatOption("cancel") {
                        AIStub.log("cancel \(logName) after reply chars \(reply.count)")
                        stop()
                        return
                    }
                    #endif
                }
                try Task.checkCancellation()
                self?.finishTurn(token: token)
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

    private func finishTurn(token: Int) {
        guard generation == token else { return }
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
