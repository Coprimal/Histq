// Incremental Server-Sent Events parser for the chat-completions and Anthropic Messages streams (ported from Dblore's
// `AISSEParser`, without the Responses wire and native Gemini). It takes the raw bytes as they arrive, so an event
// split across network chunks, a CRLF split between two chunks and a UTF-8 character split in the middle are all
// reassembled here, where tests can reach them without a network. Tool calls are model output: untrusted data,
// checked here (offered name, JSON object arguments, size caps) before they leave the parser.
import Foundation

public enum AIStreamDelta: Equatable, Sendable {
    /// A piece of the model's answer text.
    case text(String)
    /// A complete, validated tool call (offered tool, JSON object arguments within the caps).
    case toolCall(AIToolCall)
    /// Why the model ended its turn; at most one per stream.
    case stop(AIStopReason)
    /// The provider ended the stream (`data: [DONE]` or Anthropic's `message_stop`).
    case done
}

public enum AIStreamError: Error, Equatable, Sendable, CustomStringConvertible {
    /// An error event the provider sent in the stream; the text is the provider's message.
    case provider(String)
    /// One line went past `AISSEParser.maxLineBytes` without a line break.
    case lineTooLong
    /// A tool call that is refused (not offered, malformed, over a cap or cut off); the text never holds model or
    /// repository text.
    case invalidToolCall(String)

    public var description: String {
        switch self {
        case .provider(let message): message
        case .lineTooLong: "The provider sent an oversized stream line."
        case .invalidToolCall(let message): message
        }
    }
}

/// Feed the response bytes with `consume(_:)` and call `finish()` at the end of the body. Lines end with LF, CRLF or
/// a lone CR (the SSE spec allows all three); a blank line dispatches the buffered event; `:` lines are comments
/// (keepalives) and are skipped.
///
/// Without `toolNames` the parser reads text only (tool calls are ignored, as `AIChatClient.stream(_:)` wants). With
/// a set (maybe empty) it also assembles tool calls to those names: Anthropic `content_block_start` (tool_use) →
/// `input_json_delta` pieces → `content_block_stop`; chat-completions `delta.tool_calls` fragments joined by `index`
/// and completed at `finish_reason`. It then also ends a terminated stream (`[DONE]`, `message_stop`) with exactly
/// one `.stop`: the provider's reason, or `.endTurn` when none arrived. A body that ends without a terminator yields
/// no synthesized stop.
public struct AISSEParser: Sendable {
    /// The longest line buffered. A real event line is a few KB; this bounds the memory a broken or hostile server
    /// can make the client hold by never sending a line break.
    public static let maxLineBytes = 1 << 20
    /// Max bytes of one tool call's streamed arguments.
    public static let maxToolInputBytes = 64 * 1024
    /// Max tool calls assembled at once.
    public static let maxPendingToolCalls = 32
    /// Max bytes of one tool call id.
    public static let maxToolIDBytes = 256

    private struct PendingToolCall: Sendable {
        var id: String?
        var name: String?
        var input = ""
    }

    private let wire: AIWire
    /// The offered tool names; nil reads text only.
    private let toolNames: Set<String>?
    private var line: [UInt8] = []
    /// The last byte was a CR, so an LF right after it (maybe in the next chunk) ends no second line.
    private var afterCR = false
    private var eventName: String?
    private var dataLines: [String] = []
    /// Tool calls being assembled, keyed by Anthropic block index or chat-completions call index.
    private var pendingTools: [Int: PendingToolCall] = [:]
    /// A `.stop` was emitted, so no second one is.
    private var stopped = false

    public init(wire: AIWire, toolNames: Set<String>? = nil) {
        self.wire = wire
        self.toolNames = toolNames
    }

    /// Consumes the next bytes of the body and returns the deltas of every event they complete.
    public mutating func consume(_ chunk: some Sequence<UInt8>) throws(AIStreamError) -> [AIStreamDelta] {
        var out: [AIStreamDelta] = []
        for byte in chunk {
            switch byte {
            case 0x0A:
                if afterCR {
                    afterCR = false
                    continue
                }
                out += try endLine()
            case 0x0D:
                afterCR = true
                out += try endLine()
            default:
                afterCR = false
                guard line.count < Self.maxLineBytes else { throw .lineTooLong }
                line.append(byte)
            }
        }
        return out
    }

    /// The body ended: an unterminated last line and an event without its blank line are still dispatched. A tool
    /// call still being assembled was cut off and is refused.
    public mutating func finish() throws(AIStreamError) -> [AIStreamDelta] {
        var out: [AIStreamDelta] = []
        if !line.isEmpty { out += try endLine() }
        out += try dispatch()
        try checkNoPendingTools()
        return out
    }

    /// Decodes the buffered line only once it is whole, so a multi-byte character split across chunks is intact.
    private mutating func endLine() throws(AIStreamError) -> [AIStreamDelta] {
        let text = String(decoding: line, as: UTF8.self)
        line.removeAll(keepingCapacity: true)
        return try consume(line: text)
    }

    private mutating func consume(line: String) throws(AIStreamError) -> [AIStreamDelta] {
        if line.isEmpty { return try dispatch() }
        if line.hasPrefix(":") { return [] }

        let name: String
        var value: Substring
        if let colon = line.firstIndex(of: ":") {
            name = String(line[..<colon])
            value = line[line.index(after: colon)...]
            if value.hasPrefix(" ") { value = value.dropFirst() }
        } else {
            name = line
            value = ""
        }
        switch name {
        case "event": eventName = String(value)
        case "data": dataLines.append(String(value))
        default: break
        }
        return []
    }

    private mutating func dispatch() throws(AIStreamError) -> [AIStreamDelta] {
        defer {
            eventName = nil
            dataLines = []
        }
        guard !dataLines.isEmpty else { return [] }
        let data = dataLines.joined(separator: "\n")
        if data.trimmingCharacters(in: .whitespaces) == "[DONE]" { return try endStream() }
        guard let object = try? JSONSerialization.jsonObject(with: Data(data.utf8)) as? [String: Any] else {
            return []
        }
        switch wire {
        case .chatCompletions: return try chatDeltas(object)
        case .anthropicMessages: return try anthropicDeltas(object)
        }
    }

    /// Only the first choice is read. A `choices: []` chunk (the usage chunk of `stream_options.include_usage`) and
    /// reasoning deltas yield nothing. Tool call fragments join by `index`; a later fragment's absent or null id or
    /// name never overwrites the first one. A non-empty `finish_reason` completes every pending call, then stops.
    private mutating func chatDeltas(_ object: [String: Any]) throws(AIStreamError) -> [AIStreamDelta] {
        if let message = Self.errorMessage(object) { throw .provider(message) }
        guard let choices = object["choices"] as? [[String: Any]], let choice = choices.first else { return [] }
        var out: [AIStreamDelta] = []
        let delta = choice["delta"] as? [String: Any]
        if let content = delta?["content"] as? String, !content.isEmpty { out.append(.text(content)) }
        if toolNames != nil {
            let fragments = delta?["tool_calls"] as? [[String: Any]] ?? []
            for (position, fragment) in fragments.enumerated() {
                let function = fragment["function"] as? [String: Any]
                try appendTool(
                    index: fragment["index"] as? Int ?? position, id: fragment["id"] as? String,
                    name: function?["name"] as? String, input: function?["arguments"] as? String ?? "")
            }
        }
        if let reason = choice["finish_reason"] as? String, !reason.isEmpty {
            for index in pendingTools.keys.sorted() { out.append(try finishTool(index: index)) }
            out += stop(Self.chatStopReason(reason))
        }
        return out
    }

    /// `text_delta` pieces are text; a tool_use block is assembled from its `input_json_delta` pieces and completed
    /// at its `content_block_stop`; `message_delta` carries the stop reason. Thinking deltas, pings and the other
    /// block events yield nothing.
    private mutating func anthropicDeltas(_ object: [String: Any]) throws(AIStreamError) -> [AIStreamDelta] {
        switch (object["type"] as? String) ?? eventName {
        case "error":
            throw .provider(Self.errorMessage(object) ?? "The provider returned an error.")
        case "message_stop":
            return try endStream()
        case "content_block_start":
            guard toolNames != nil, let index = object["index"] as? Int,
                let block = object["content_block"] as? [String: Any], block["type"] as? String == "tool_use"
            else { return [] }
            guard let id = block["id"] as? String, let name = block["name"] as? String else {
                throw .invalidToolCall("The model sent a tool call without an id or a name.")
            }
            try appendTool(index: index, id: id, name: name, input: "")
            return []
        case "content_block_delta":
            guard let delta = object["delta"] as? [String: Any] else { return [] }
            switch delta["type"] as? String {
            case "text_delta":
                guard let text = delta["text"] as? String, !text.isEmpty else { return [] }
                return [.text(text)]
            case "input_json_delta":
                guard let index = object["index"] as? Int, pendingTools[index] != nil,
                    let piece = delta["partial_json"] as? String
                else { return [] }
                try appendTool(index: index, id: nil, name: nil, input: piece)
                return []
            default:
                return []
            }
        case "content_block_stop":
            guard let index = object["index"] as? Int, pendingTools[index] != nil else { return [] }
            return [try finishTool(index: index)]
        case "message_delta":
            guard let delta = object["delta"] as? [String: Any], let reason = delta["stop_reason"] as? String,
                !reason.isEmpty
            else { return [] }
            return stop(Self.anthropicStopReason(reason))
        default:
            return []
        }
    }

    /// Adds one streamed piece to a pending tool call, refusing a call over the count cap, an oversized id, a name
    /// that was not offered or arguments over the cap before they are buffered.
    private mutating func appendTool(index: Int, id: String?, name: String?, input: String) throws(AIStreamError) {
        if pendingTools[index] == nil, pendingTools.count >= Self.maxPendingToolCalls {
            throw .invalidToolCall("The model sent too many tool calls.")
        }
        // Taken out, so appending to its input does not copy the buffered arguments.
        var call = pendingTools.removeValue(forKey: index) ?? PendingToolCall()
        if let id, call.id == nil {
            guard id.utf8.count <= Self.maxToolIDBytes else {
                throw .invalidToolCall("The model sent an oversized tool call id.")
            }
            call.id = id
        }
        if let name, call.name == nil {
            guard toolNames?.contains(name) == true else {
                throw .invalidToolCall("The model called a tool that was not offered.")
            }
            call.name = name
        }
        guard call.input.utf8.count + input.utf8.count <= Self.maxToolInputBytes else {
            throw .invalidToolCall("The model sent tool arguments over 64 KiB.")
        }
        call.input += input
        pendingTools[index] = call
    }

    /// Completes a pending tool call: an id, an offered name and a JSON object (empty means `{}`). `inputJSON` is the
    /// parsed object re-serialized with sorted keys, never the raw text, so the call run and the call sent back are
    /// the one validated here.
    private mutating func finishTool(index: Int) throws(AIStreamError) -> AIStreamDelta {
        let call = pendingTools.removeValue(forKey: index) ?? PendingToolCall()
        guard let id = call.id, !id.isEmpty, let name = call.name else {
            throw .invalidToolCall("The model sent a tool call without an id or a name.")
        }
        let input = call.input.isEmpty ? "{}" : call.input
        guard let object = try? JSONSerialization.jsonObject(with: Data(input.utf8)) as? [String: Any],
            let inputJSON = Self.canonicalJSON(object)
        else { throw .invalidToolCall("The model sent tool arguments that are not a JSON object.") }
        return .toolCall(AIToolCall(id: id, name: name, inputJSON: inputJSON))
    }

    /// The object re-serialized with sorted keys; nil when it holds a value JSON cannot encode (a non-finite number:
    /// `-1e999` parses to -inf, and serializing it would raise instead of throwing).
    static func canonicalJSON(_ object: [String: Any]) -> String? {
        guard JSONSerialization.isValidJSONObject(object),
            let data = try? JSONSerialization.data(
                withJSONObject: object, options: [.sortedKeys, .withoutEscapingSlashes])
        else { return nil }
        return String(decoding: data, as: UTF8.self)
    }

    /// The first stop of the stream; later ones are dropped.
    private mutating func stop(_ reason: AIStopReason) -> [AIStreamDelta] {
        guard !stopped else { return [] }
        stopped = true
        return [.stop(reason)]
    }

    /// `[DONE]` or `message_stop`: a pending tool call was cut off; with tools, a stop when none arrived yet.
    private mutating func endStream() throws(AIStreamError) -> [AIStreamDelta] {
        try checkNoPendingTools()
        return (toolNames == nil ? [] : stop(.endTurn)) + [.done]
    }

    private func checkNoPendingTools() throws(AIStreamError) {
        guard pendingTools.isEmpty else { throw .invalidToolCall("The model's tool call was cut off.") }
    }

    private static func anthropicStopReason(_ reason: String) -> AIStopReason {
        switch reason {
        case "end_turn": .endTurn
        case "tool_use": .toolUse
        case "max_tokens": .maxTokens
        default: .other(reason)
        }
    }

    private static func chatStopReason(_ reason: String) -> AIStopReason {
        switch reason {
        case "stop": .endTurn
        case "tool_calls": .toolUse
        case "length": .maxTokens
        default: .other(reason)
        }
    }

    /// The whole message: the client scrubs the key from it before shortening it, so a cut never leaves part of a
    /// key behind.
    private static func errorMessage(_ object: [String: Any]) -> String? {
        if let text = object["error"] as? String, !text.isEmpty { return text }
        return (object["error"] as? [String: Any])?["message"] as? String
    }
}
