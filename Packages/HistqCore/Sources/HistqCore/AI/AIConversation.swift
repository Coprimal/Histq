// The saved chats of one repo (structure from Dblore's `AIConversationStore`) and the history sent to the model on
// each turn. A chat's visible text is UI only: it may hold paths and names, so the model gets `modelText` (a fixed
// app sentence) in its place when one is set, and the hidden context (the data blocks the app built) before it.
//
// The file is a contract: a JSON array of conversations, each with a `version`. Later builds only add optional
// keys, which older files decode as nil, and decoding is lenient per conversation and per entry, so a kind a build
// does not know drops that one item, never the whole file. A file that cannot be read or decoded is never taken
// as empty: the next save moves it aside first, so saved chats are never silently overwritten. Every read and
// write goes through one shared actor, so two tabs on one repo never interleave their read-merge-write.
import Foundation
import os

/// One line of a chat as the user sees it, with what the model gets for it.
public struct AIChatEntry: Codable, Sendable, Equatable, Identifiable {
    public enum Role: String, Codable, Sendable { case user, assistant, tool }

    public var id: UUID
    public var role: Role
    /// What the chat shows (UI only; may hold paths, branch names and other repository text).
    public var text: String
    /// The fixed app sentence sent to the model in place of `text`; nil when `text` is what the user typed.
    public var modelText: String?
    /// The data blocks sent before the text (a diff, a reference), never shown.
    public var hiddenContext: String?
    /// `AIIgnore.digest` of the `.aiignore` the hidden context was filtered with. A context is replayed only while
    /// it matches the worktree's current one; nil (unknown) never does.
    public var ignoreDigest: String?
    public var isError: Bool

    public init(
        id: UUID = UUID(), role: Role, text: String, modelText: String? = nil, hiddenContext: String? = nil,
        ignoreDigest: String? = nil, isError: Bool = false
    ) {
        self.id = id
        self.role = role
        self.text = text
        self.modelText = modelText
        self.hiddenContext = hiddenContext
        self.ignoreDigest = ignoreDigest
        self.isError = isError
    }

    private enum CodingKeys: String, CodingKey {
        case id, role, text, modelText, hiddenContext, ignoreDigest, isError
    }

    public init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        id = try container.decode(UUID.self, forKey: .id)
        role = try container.decode(Role.self, forKey: .role)
        text = try container.decode(String.self, forKey: .text)
        modelText = try container.decodeIfPresent(String.self, forKey: .modelText)
        hiddenContext = try container.decodeIfPresent(String.self, forKey: .hiddenContext)
        ignoreDigest = try container.decodeIfPresent(String.self, forKey: .ignoreDigest)
        isError = try container.decodeIfPresent(Bool.self, forKey: .isError) ?? false
    }
}

/// One saved chat.
public struct AIConversation: Codable, Sendable, Equatable, Identifiable {
    /// The format version this build writes.
    public static let currentVersion = 1
    public static let titleLength = 80

    public var id: UUID
    public var version: Int
    public var title: String
    public var updatedAt: Date
    public var entries: [AIChatEntry]

    /// A chat titled from its first user entry (see `title(from:)`).
    public init(id: UUID = UUID(), entries: [AIChatEntry], updatedAt: Date = .now) {
        self.id = id
        self.version = Self.currentVersion
        self.title = Self.title(from: entries)
        self.updatedAt = updatedAt
        self.entries = entries
    }

    /// The first user entry's text with whitespace collapsed, cut to `titleLength` characters; empty when there is
    /// no user entry.
    public static func title(from entries: [AIChatEntry]) -> String {
        guard let first = entries.first(where: { $0.role == .user }) else { return "" }
        let collapsed = first.text.split(whereSeparator: \.isWhitespace).joined(separator: " ")
        return String(collapsed.prefix(titleLength))
    }

    private enum CodingKeys: String, CodingKey { case id, version, title, updatedAt, entries }

    public init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        id = try container.decode(UUID.self, forKey: .id)
        version = try container.decodeIfPresent(Int.self, forKey: .version) ?? Self.currentVersion
        updatedAt = try container.decode(Date.self, forKey: .updatedAt)
        entries = try container.decode([Lenient<AIChatEntry>].self, forKey: .entries).compactMap(\.value)
        title = try container.decodeIfPresent(String.self, forKey: .title) ?? Self.title(from: entries)
    }
}

/// An array element that decodes to nil instead of failing the whole array.
private struct Lenient<Value: Decodable>: Decodable {
    let value: Value?
    init(from decoder: any Decoder) throws { value = try? Value(from: decoder) }
}

// MARK: - Store

/// The saved chats of one repo, in one JSON file (the app passes its URL). Newest first, at most `limit`.
public struct AIConversationStore: Sendable {
    public static let limit = 100

    public let url: URL

    public init(url: URL) {
        self.url = url
    }

    /// The saved chats, newest first; `[]` only when the file does not exist. Throws when it cannot be read or
    /// decoded.
    public func load() async throws -> [AIConversation] {
        try await AIConversationFiles.shared.load(url)
    }

    /// Re-reads the file, replaces the chat with `conversation`'s id (or adds it), keeps the `limit` newest and
    /// writes the file. Returns the saved list, newest first.
    @discardableResult
    public func upsert(_ conversation: AIConversation) async throws -> [AIConversation] {
        try await AIConversationFiles.shared.update(url) { conversations in
            conversations.removeAll { $0.id == conversation.id }
            conversations.append(conversation)
        }
    }

    /// Re-reads the file, removes the chat with `id` and writes the file. Returns the saved list, newest first.
    @discardableResult
    public func delete(id: UUID) async throws -> [AIConversation] {
        try await AIConversationFiles.shared.update(url) { conversations in
            conversations.removeAll { $0.id == id }
        }
    }
}

/// Every chat file's reads and writes, one at a time. Each method runs start to end without a suspension point, so
/// a read-merge-write never interleaves with another (one actor for all files keeps it simple; the files are small).
actor AIConversationFiles {
    static let shared = AIConversationFiles()

    private static let logger = Logger(subsystem: "com.math2it.histq", category: "ai-chat")

    func load(_ url: URL) throws -> [AIConversation] {
        let data: Data
        do {
            data = try Data(contentsOf: url)
        } catch CocoaError.fileReadNoSuchFile {
            return []
        }
        let items = try JSONDecoder().decode([Lenient<AIConversation>].self, from: data)
        let conversations = items.compactMap(\.value)
        // Nothing decodable in a non-empty file is a format this build does not read, not an empty list.
        if conversations.isEmpty, !items.isEmpty {
            throw CocoaError(.fileReadCorruptFile, userInfo: [NSFilePathErrorKey: url.path])
        }
        return conversations.sorted { $0.updatedAt > $1.updatedAt }
    }

    /// Re-reads `url` (an unreadable file is moved aside first, then counts as empty), applies `change`, keeps the
    /// `AIConversationStore.limit` newest and writes the file.
    func update(_ url: URL, _ change: @Sendable (inout [AIConversation]) -> Void) throws -> [AIConversation] {
        var conversations: [AIConversation]
        do {
            conversations = try load(url)
        } catch {
            try moveAside(url, error: error)
            conversations = []
        }
        change(&conversations)
        conversations.sort { $0.updatedAt > $1.updatedAt }
        conversations = Array(conversations.prefix(AIConversationStore.limit))
        try write(conversations, to: url)
        return conversations
    }

    /// Renames an unreadable file to `<name>.unreadable-<milliseconds>`; never replaces a file already there.
    private func moveAside(_ url: URL, error: any Error) throws {
        let stamp = Int64(Date.now.timeIntervalSince1970 * 1000)
        let aside = url.deletingLastPathComponent().appending(path: "\(url.lastPathComponent).unreadable-\(stamp)")
        try FileManager.default.moveItem(at: url, to: aside)
        Self.logger.error(
            "Chats file could not be read (\(String(describing: error))), moved to \(aside.lastPathComponent, privacy: .public)"
        )
    }

    /// Writes atomically (a temp file in the same folder, then `rename(2)`) with mode 600, as `ProfileStore.save`
    /// does: chats hold repository content. The folder is created if missing.
    private func write(_ conversations: [AIConversation], to url: URL) throws {
        let data = try JSONEncoder().encode(conversations)
        let folder = url.deletingLastPathComponent()
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let temp = folder.appending(path: ".\(url.lastPathComponent).\(UUID().uuidString).tmp")
        let fd = open(temp.path, O_WRONLY | O_CREAT | O_EXCL | O_CLOEXEC, 0o600)
        guard fd >= 0 else { throw CocoaError(.fileWriteUnknown, userInfo: [NSFilePathErrorKey: temp.path]) }
        do {
            let handle = FileHandle(fileDescriptor: fd, closeOnDealloc: true)
            try handle.write(contentsOf: data)
            try handle.synchronize()
            try handle.close()
            guard rename(temp.path, url.path) == 0 else {
                throw CocoaError(.fileWriteUnknown, userInfo: [NSFilePathErrorKey: url.path])
            }
        } catch {
            unlink(temp.path)
            throw error
        }
    }
}

// MARK: - History

/// The messages sent for a chat's next turn.
public enum AIChatHistory {
    public static let entryLimit = 20
    public static let omittedContext = "(earlier context omitted)"
    static let restOmitted = "(rest of the context omitted)"
    static let blockCutNote = "[Histq: the rest of this data was left out to fit the size budget]\n"

    /// The model's view of `entries`: the last `entryLimit` that count (errors, empty entries and a leading
    /// assistant message are skipped). A user or tool entry becomes a user message of its hidden context, then
    /// `modelText ?? text`; a hidden context whose `ignoreDigest` is not `ignoreDigest` (the worktree's current
    /// `.aiignore`, nil when it could not be read) is replaced by `omittedContext`, so a context filtered with older
    /// rules is never sent again. `budget` is in UTF-8 bytes (as `AIPrompts.diffBudget`): past it, the oldest hidden
    /// contexts are replaced by `omittedContext`, and when the newest message is still over it, its own context is
    /// cut (whole data blocks first, then one block's text, the block still closed). Adjacent messages with the same
    /// role are then merged, so the list alternates and starts and ends with a user message.
    public static func messages(from entries: [AIChatEntry], budget: Int, ignoreDigest: String?) -> [AIChatMessage] {
        var turns = Array(entries.compactMap { turn(for: $0, ignoreDigest: ignoreDigest) }.suffix(entryLimit))
        while turns.first?.role == .assistant { turns.removeFirst() }
        while turns.last?.role == .assistant { turns.removeLast() }
        fit(&turns, budget: budget)

        var messages: [AIChatMessage] = []
        for turn in turns {
            if let last = messages.last, last.role == turn.role {
                messages[messages.count - 1] = AIChatMessage(role: turn.role, text: last.text + "\n\n" + turn.text)
            } else {
                messages.append(AIChatMessage(role: turn.role, text: turn.text))
            }
        }
        return messages
    }

    private struct Turn {
        var role: AIChatMessage.Role
        var context: String?
        var body: String

        var text: String {
            guard let context, !context.isEmpty else { return body }
            return context + (context.utf8.last == 0x0A ? "\n" : "\n\n") + body
        }
    }

    private static func turn(for entry: AIChatEntry, ignoreDigest: String?) -> Turn? {
        guard !entry.isError else { return nil }
        let body = entry.modelText ?? entry.text
        switch entry.role {
        case .assistant:
            return isBlank(body) ? nil : Turn(role: .assistant, context: nil, body: body)
        case .user, .tool:
            // Saved tool calls and outputs replay as user text (never as native tool blocks).
            if isBlank(body), isBlank(entry.hiddenContext ?? "") { return nil }
            var context = entry.hiddenContext
            // Two nils never match: an unknown digest or an unreadable `.aiignore` omits the context.
            if let hidden = context, !isBlank(hidden), ignoreDigest == nil || entry.ignoreDigest != ignoreDigest {
                context = omittedContext
            }
            return Turn(role: .user, context: context, body: body)
        }
    }

    private static func isBlank(_ text: String) -> Bool {
        text.allSatisfy(\.isWhitespace)
    }

    /// The bytes `turns` take once merged (a two-byte separator counted between every pair, which is never less).
    private static func size(_ turns: [Turn]) -> Int {
        turns.reduce(0) { $0 + $1.text.utf8.count } + 2 * max(0, turns.count - 1)
    }

    private static func fit(_ turns: inout [Turn], budget: Int) {
        var total = size(turns)
        guard total > budget, let newest = turns.indices.last else { return }
        for index in turns.indices where index != newest && total > budget {
            guard let context = turns[index].context, !context.isEmpty, context != omittedContext else { continue }
            let before = turns[index].text.utf8.count
            turns[index].context = omittedContext
            total += turns[index].text.utf8.count - before
        }
        guard total > budget, let context = turns[newest].context, !context.isEmpty else { return }
        // The room left for the newest context, its separator before the body taken off.
        let room = budget - (total - turns[newest].text.utf8.count) - turns[newest].body.utf8.count - 2
        let cut = self.cut(context, toBytes: room)
        turns[newest].context = cut.isEmpty ? nil : cut
    }

    // MARK: Cutting a context

    private enum Part {
        case text(String)
        /// The app line naming the token and the BEGIN line; the data; the END line.
        case block(header: String, inner: String, end: String)

        var rendered: String {
            switch self {
            case .text(let text): text
            case .block(let header, let inner, let end): header + inner + end
            }
        }
    }

    /// `context` cut to at most `limit` UTF-8 bytes: its parts in order while they fit whole; then the first data
    /// block that does not fit keeps the start of its text (at a line end when there is one) and a note, and its
    /// END line; then a closing note. Text outside a closed block is kept whole or not at all, so the result never
    /// opens a block it does not close.
    static func cut(_ context: String, toBytes limit: Int) -> String {
        guard context.utf8.count > limit else { return context }
        // One byte more for the line end the kept text may need before the closing note.
        let budget = limit - restOmitted.utf8.count - 1
        guard budget >= 0 else { return "" }
        var out = ""
        var used = 0
        for part in parts(of: context) {
            let whole = part.rendered
            if used + whole.utf8.count <= budget {
                out += whole
                used += whole.utf8.count
                continue
            }
            if case .block(let header, let inner, let end) = part {
                // One byte more for the line end the cut text may need before the note.
                let room = budget - used - header.utf8.count - end.utf8.count - blockCutNote.utf8.count - 1
                if room > 0 {
                    var kept = prefix(inner, bytes: room)
                    if !kept.isEmpty, kept.utf8.last != 0x0A { kept += "\n" }
                    out += header + kept + blockCutNote + end
                }
            }
            break
        }
        if !out.isEmpty, out.utf8.last != 0x0A { out += "\n" }
        return out + restOmitted
    }

    /// The start of `text` in at most `bytes` UTF-8 bytes, cut after its last line end when it has one.
    private static func prefix(_ text: String, bytes: Int) -> String {
        var end = text.startIndex
        var used = 0
        for index in text.indices {
            let size = text[index].utf8.count
            guard used + size <= bytes else { break }
            used += size
            end = text.index(after: index)
        }
        let head = text[..<end]
        if let newline = head.utf8.lastIndex(of: 0x0A) {
            return String(head[...newline])
        }
        return String(head)
    }

    /// `context` split into text and closed data blocks. A block starts at a "BEGIN DATA <token>" line and ends at
    /// the first line that is exactly "END DATA <token>" with the same token, so a forged line inside the data
    /// changes nothing; the app line right before the BEGIN line that names the token belongs to the block. A BEGIN
    /// line with no matching END stays text.
    private static func parts(of context: String) -> [Part] {
        let lines = lines(of: context)
        var parts: [Part] = []
        var pending: [Substring] = []
        var index = 0
        while index < lines.count {
            let line = content(of: lines[index])
            if line.hasPrefix("BEGIN DATA "), case let token = line.dropFirst("BEGIN DATA ".count), !token.isEmpty,
               let endIndex = lines[(index + 1)...].firstIndex(where: { content(of: $0) == "END DATA \(token)" }) {
                var header = ""
                if let last = pending.last, last.contains("BEGIN DATA \(token)") {
                    header = String(last)
                    pending.removeLast()
                }
                if !pending.isEmpty { parts.append(.text(pending.joined())) }
                pending = []
                header += lines[index]
                parts.append(.block(
                    header: header, inner: lines[(index + 1)..<endIndex].joined(), end: String(lines[endIndex])
                ))
                index = endIndex + 1
            } else {
                pending.append(lines[index])
                index += 1
            }
        }
        if !pending.isEmpty { parts.append(.text(pending.joined())) }
        return parts
    }

    /// `text`'s lines, each with its line end ("\n"; the last one may have none).
    private static func lines(of text: String) -> [Substring] {
        var lines: [Substring] = []
        var start = text.startIndex
        while start < text.endIndex {
            guard let newline = text.utf8[start...].firstIndex(of: 0x0A) else {
                lines.append(text[start...])
                break
            }
            let next = text.utf8.index(after: newline)
            lines.append(text[start..<next])
            start = next
        }
        return lines
    }

    /// A line without its line end ("\n" or "\r\n").
    private static func content(of line: Substring) -> Substring {
        line.utf8.last == 0x0A ? line.dropLast() : line
    }
}
