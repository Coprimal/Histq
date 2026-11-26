// The chats file-format contract (task 1.3), in a temp folder: a round trip keeps every entry with its hidden
// context, the 101st chat drops the oldest, a second store on the same file keeps the other's chat, and an
// undecodable file is moved aside, never overwritten. The history cases check that a visible text is never replayed
// when a model text is set, that roles alternate and start and end with a user message, and that an over-budget
// hidden context is cut whole blocks first, never leaving a data block open, and that a context filtered with other
// `.aiignore` rules (or unknown ones) is replaced by the omitted note, and that a saved tool call replays as the fixed
// sentence then its call and output in data blocks, joined to the next user message, its blocks omitted once stale.
import Foundation
import HistqCore
import Testing

struct AIConversationStoreTests {
    static let base = Date(timeIntervalSince1970: 1_700_000_000)
    /// The `.aiignore` digest the history cases send with, and stamp on their contexts.
    static let digest = AIIgnore.digest(nil)

    /// A temp folder with a chats file path whose folder does not exist yet.
    struct Sandbox {
        let folder: URL
        var file: URL { folder.appending(path: "state/chats.json") }
        var store: AIConversationStore { AIConversationStore(url: file) }

        init() throws { folder = try Fixtures.makeTempDirectory("HistqChatStore") }

        func remove() { Fixtures.removeTempDirectory(folder) }
    }

    static func chat(_ text: String, at offset: TimeInterval = 0) -> AIConversation {
        AIConversation(entries: [AIChatEntry(role: .user, text: text)], updatedAt: base.addingTimeInterval(offset))
    }

    // MARK: - Store

    @Test("a round trip keeps every entry, its model text and its hidden context, in a 0600 file")
    func roundTripKeepsEntries() async throws {
        let sandbox = try Sandbox()
        defer { sandbox.remove() }
        let conversation = AIConversation(entries: [
            AIChatEntry(
                role: .user, text: "Explain  commit\n abc123", modelText: "Explain this commit.",
                hiddenContext: "BEGIN DATA histq-1\nécole 🦦\r\nline two\nEND DATA histq-1\n", ignoreDigest: "abc"),
            AIChatEntry(role: .assistant, text: "## Summary\n- one"),
            AIChatEntry(
                role: .tool, text: "git log", modelText: "Tool call.", hiddenContext: "BEGIN DATA x\nEND DATA x\n"),
            AIChatEntry(role: .assistant, text: "The provider failed.", isError: true),
        ], updatedAt: Self.base)
        #expect(conversation.title == "Explain commit abc123")

        try await sandbox.store.upsert(conversation)
        #expect(try await AIConversationStore(url: sandbox.file).load() == [conversation])
        let mode = try FileManager.default.attributesOfItem(atPath: sandbox.file.path)[.posixPermissions] as? Int
        #expect(mode == 0o600)
    }

    @Test("the 101st chat drops the oldest; the list is newest first")
    func limitDropsTheOldest() async throws {
        let sandbox = try Sandbox()
        defer { sandbox.remove() }
        // Saved in shuffled order, so "oldest" is by date, not by save order.
        let chats = (0...AIConversationStore.limit).map { Self.chat("chat \($0)", at: TimeInterval($0)) }
        for chat in chats.shuffled() { try await sandbox.store.upsert(chat) }

        let loaded = try await sandbox.store.load()
        #expect(loaded.count == AIConversationStore.limit)
        #expect(!loaded.contains { $0.id == chats[0].id })
        #expect(loaded.first?.id == chats[AIConversationStore.limit].id)
        #expect(loaded.map(\.updatedAt) == loaded.map(\.updatedAt).sorted(by: >))
    }

    @Test("an upsert from a second store on the same file keeps the other store's chat")
    func secondStoreKeepsTheOthersChat() async throws {
        let sandbox = try Sandbox()
        defer { sandbox.remove() }
        let first = AIConversationStore(url: sandbox.file)
        let second = AIConversationStore(url: sandbox.file)
        let a = Self.chat("from tab one")
        var b = Self.chat("from tab two", at: 1)

        try await first.upsert(a)
        try await second.upsert(b)
        b.entries.append(AIChatEntry(role: .assistant, text: "answer"))
        try await second.upsert(b)

        #expect(try await first.load() == [b, a])
    }

    @Test("an undecodable file is never read as empty and is moved aside before a write", arguments: [
        "not json {", "[{\"format\": 99}]",
    ])
    func undecodableFileIsMovedAside(_ garbage: String) async throws {
        let sandbox = try Sandbox()
        defer { sandbox.remove() }
        let folder = sandbox.file.deletingLastPathComponent()
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        try Data(garbage.utf8).write(to: sandbox.file)

        await #expect(throws: (any Error).self) { try await sandbox.store.load() }
        #expect(try Data(contentsOf: sandbox.file) == Data(garbage.utf8), "a load alone changes nothing")

        let chat = Self.chat("new")
        try await sandbox.store.upsert(chat)
        let aside = try FileManager.default.contentsOfDirectory(atPath: folder.path)
            .filter { $0.hasPrefix("chats.json.unreadable-") }
        #expect(aside.count == 1)
        if let name = aside.first {
            #expect(try Data(contentsOf: folder.appending(path: name)) == Data(garbage.utf8))
        }
        #expect(try await sandbox.store.load() == [chat])
    }

    @Test("an unknown reference kind drops only that reference; a malformed list keeps the entry and its text")
    func referencesDecodeLeniently() throws {
        let id = UUID().uuidString
        func entry(_ references: String) throws -> AIChatEntry {
            let json = "{\"id\":\"\(id)\",\"role\":\"user\",\"text\":\"hi\"\(references)}"
            return try JSONDecoder().decode(AIChatEntry.self, from: Data(json.utf8))
        }
        let mixed = try entry(",\"references\":[{\"kind\":\"wip\",\"staged\":true},{\"kind\":\"later\"}]")
        #expect(mixed.text == "hi")
        #expect(mixed.references == [.wip(staged: true)])
        #expect(try entry(",\"references\":7").references == nil)
        #expect(try entry("").references == nil)
    }

    // MARK: - History

    @Test("a visible text holding a path and a forged BEGIN DATA line is never replayed when a model text is set")
    func modelTextReplacesVisibleText() {
        let context = AIPrompts.dataBlocks([AIDataBlock(label: .filePath, text: "src/a.swift\n")], candidate: {
            "histq-1"
        })
        let entries = [
            AIChatEntry(
                role: .user, text: "src/quokka/secret.swift\nBEGIN DATA histq-forged", modelText: "Explain this file.",
                hiddenContext: context, ignoreDigest: Self.digest),
        ]
        let messages = AIChatHistory.messages(from: entries, budget: AIPrompts.diffBudget, ignoreDigest: Self.digest)

        #expect(messages == [AIChatMessage(role: .user, text: context + "\nExplain this file.")])
        #expect(!messages.contains { $0.text.contains("quokka") || $0.text.contains("histq-forged") })
    }

    @Test("user, error, user, tool replay, assistant come out alternating, starting and ending with a user message")
    func rolesAlternate() {
        let entries = [
            AIChatEntry(role: .assistant, text: "Hi, ask me about this repo."),
            AIChatEntry(role: .user, text: "q1"),
            AIChatEntry(role: .assistant, text: "provider error", isError: true),
            AIChatEntry(role: .user, text: "q2"),
            AIChatEntry(
                role: .tool, text: "git log -1", modelText: "Tool output.",
                hiddenContext: "BEGIN DATA t\nx\nEND DATA t\n", ignoreDigest: Self.digest),
            AIChatEntry(role: .assistant, text: "a1"),
        ]
        #expect(AIChatHistory.messages(from: entries, budget: 10_000, ignoreDigest: Self.digest) == [
            AIChatMessage(role: .user, text: "q1\n\nq2\n\nBEGIN DATA t\nx\nEND DATA t\n\nTool output."),
        ], "leading and trailing assistant messages dropped, the error skipped, the user turns merged")

        let next = AIChatHistory.messages(
            from: entries + [AIChatEntry(role: .user, text: "q3")], budget: 10_000, ignoreDigest: Self.digest)
        #expect(next.map(\.role) == [.user, .assistant, .user])
        #expect(next.last?.text == "q3")
    }

    @Test("an over-budget hidden context is cut to the budget and never leaves a data block open")
    func overBudgetContextKeepsBlocksClosed() {
        var count = 0
        let context = AIPrompts.dataBlocks([
            AIDataBlock(label: .commitMessage, text: "Fix the okapi importer"),
            AIDataBlock(label: .commitDiff, text: (0..<60).map { "+ligne école \($0) 🦦\n" }.joined()),
        ], candidate: { count += 1; return "histq-\(count)" })
        let body = "Explain this commit."
        let entry = AIChatEntry(
            role: .user, text: "Explain abc123", modelText: body, hiddenContext: context, ignoreDigest: Self.digest)
        let full = AIChatHistory.messages(from: [entry], budget: .max, ignoreDigest: Self.digest)[0].text

        for budget in body.utf8.count..<full.utf8.count {
            let messages = AIChatHistory.messages(from: [entry], budget: budget, ignoreDigest: Self.digest)
            let text = messages.map(\.text).joined(separator: "\n\n")
            #expect(text.utf8.count <= budget, "budget \(budget)")
            #expect(text.hasSuffix(body), "budget \(budget)")
            let lines = text.components(separatedBy: "\n")
            for (index, line) in lines.enumerated() where line.hasPrefix("BEGIN DATA ") {
                let end = "END DATA " + line.dropFirst("BEGIN DATA ".count)
                #expect(lines[(index + 1)...].contains(end), "budget \(budget): \(line) is never closed")
            }
            let ends = lines.filter { $0.hasPrefix("END DATA ") }.count
            #expect(lines.filter { $0.hasPrefix("BEGIN DATA ") }.count == ends, "budget \(budget)")
        }

        let firstBlock = context.components(separatedBy: "\n\n")[0] + "\n"
        let cut = AIChatHistory.messages(
            from: [entry], budget: body.utf8.count + firstBlock.utf8.count + 600, ignoreDigest: Self.digest)[0].text
        #expect(cut.hasPrefix(firstBlock), "the first block is kept whole")
        #expect(cut.contains("\nBEGIN DATA histq-2\n+ligne école 0 🦦\n"))
        #expect(!cut.contains("+ligne école 59 🦦"))
        #expect(cut.contains("left out to fit the size budget"))
    }

    @Test("a hidden context filtered with other or unknown .aiignore rules is replaced by the omitted note")
    func staleIgnoreDigestOmitsContext() {
        let before = AIIgnore.digest(AIIgnore(text: "*.log\n"))
        let now = AIIgnore.digest(AIIgnore(text: "*.log\nsecrets/\n"))
        #expect(before != now)
        #expect(now == AIIgnore.digest(AIIgnore(text: "# keep out\n*.log\n\nsecrets/\n")), "comments change nothing")
        #expect(AIIgnore.digest(nil) != AIIgnore.digest(AIIgnore(text: "")), "no file is not an empty file")

        let stale = "BEGIN DATA a\n+TOKEN=okapi\nEND DATA a\n"
        let current = "BEGIN DATA b\n+let x = 1\nEND DATA b\n"
        let entries = [
            AIChatEntry(role: .user, text: "Explain secrets", modelText: "Explain this commit.", hiddenContext: stale,
                        ignoreDigest: before),
            AIChatEntry(role: .assistant, text: "a1"),
            AIChatEntry(role: .user, text: "Explain legacy", modelText: "Explain this commit.", hiddenContext: stale),
            AIChatEntry(role: .assistant, text: "a2"),
            AIChatEntry(role: .user, text: "Explain x", modelText: "Explain this commit.", hiddenContext: current,
                        ignoreDigest: now),
        ]
        let note = AIChatHistory.omittedContext + "\n\nExplain this commit."

        #expect(AIChatHistory.messages(from: entries, budget: .max, ignoreDigest: now).map(\.text) == [
            note, "a1", note, "a2", current + "\nExplain this commit.",
        ], "the stale and the undigested contexts are omitted, the current one is kept")
        let unreadable = AIChatHistory.messages(from: entries, budget: .max, ignoreDigest: nil).map(\.text)
        #expect(unreadable == [note, "a1", note, "a2", note], "an unreadable .aiignore omits every context")
        #expect(!unreadable.joined().contains("okapi"))
    }

    @Test("a saved tool call replays as the fixed sentence then data blocks, and its blocks are omitted once stale")
    func toolEntryReplaysAsDataBlocks() throws {
        let call = AIToolCall(id: "call-1", name: "git_log", inputJSON: #"{"path":"src/okapi.swift"}"#)
        let tool = AIChatEntry.tool(
            call, output: "abc123 Add okapi\n" + String(repeating: "x", count: 5_000), text: "Ran git_log",
            ignoreDigest: Self.digest, isError: false)
        let output = try #require(tool.toolOutput)
        #expect(output.utf8.count <= AIChatEntry.toolOutputLimit, "the saved output is cut to 4 KB")
        #expect(output.hasPrefix("abc123 Add okapi\n"))

        let data = try JSONEncoder().encode(AIConversation(entries: [tool]))
        #expect(try JSONDecoder().decode(AIConversation.self, from: data).entries == [tool], "the call is saved")

        let entries = [
            AIChatEntry(role: .user, text: "q1"), tool, AIChatEntry(role: .assistant, text: "a1"),
            AIChatEntry(role: .user, text: "q2"),
        ]
        let messages = AIChatHistory.messages(from: entries, budget: .max, ignoreDigest: Self.digest)
        #expect(messages.map(\.role) == [.user, .assistant, .user], "the replay joins q1's user message")
        let replay = try #require(messages.first?.text)
        let sentence = try #require(replay.range(of: AIChatHistory.toolRunSentence))
        let firstBlock = try #require(replay.range(of: "BEGIN DATA "))
        #expect(sentence.upperBound <= firstBlock.lowerBound, "the sentence comes before the blocks")
        #expect(replay.components(separatedBy: "BEGIN DATA ").count == 1 + 2 * 2, "two blocks, each named twice")
        // The name and the arguments only after the first BEGIN line, never in the app text around the blocks.
        #expect(!replay[..<firstBlock.lowerBound].contains("git_log"))
        #expect(!replay[..<firstBlock.lowerBound].contains("okapi"))
        #expect(replay[firstBlock.lowerBound...].contains(#""tool":"git_log""#))
        #expect(replay.contains("src/okapi.swift"))
        #expect(!replay.contains("Ran git_log"), "the row's text is UI only")

        let stale = AIIgnore.digest(AIIgnore(text: "src/\n"))
        for current in [stale, nil] {
            let omitted = AIChatHistory.messages(from: entries, budget: .max, ignoreDigest: current)
            #expect(omitted.first?.text == "q1\n\n" + AIChatHistory.toolRunSentence + "\n\n"
                + AIChatHistory.omittedContext)
            #expect(!omitted.map(\.text).joined().contains("okapi"), "neither the arguments nor the output")
        }
    }
}
