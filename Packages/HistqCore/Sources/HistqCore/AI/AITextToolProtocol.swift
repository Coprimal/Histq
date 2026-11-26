// Tool calls as text, for wires without native tool calls (custom endpoints and Gemini, phase 5): the system prompt
// lists the tools and the model answers with one fenced ```tool block of strict JSON (ported from Dblore's
// `AITextToolProtocol` and `AIMessageParser.toolCall`). The block is model output: untrusted data, never instructions.
// Results go back as user text in `AIPrompts.dataBlocks`, and a history with tool blocks is turned into plain text
// messages, since `AIProviderRequests` sends any tool block natively.
import Foundation

public enum AITextToolProtocol {
    /// Fence language of a tool call block.
    public static let fenceLanguage = "tool"

    /// What the model's full reply is.
    public enum Reply: Sendable, Equatable {
        /// No tool block: the reply is the answer.
        case answer(String)
        case call(AIToolCall)
        /// A tool block that is refused, with a fixed app sentence saying why (never model text).
        case invalid(String)
    }

    /// The system prompt section that lists `tools` (name, description and the arguments' JSON Schema as compact
    /// JSON) and the reply format. Names and descriptions are app strings.
    public static func systemSection(tools: [AIToolSpec]) -> String {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        let list = tools.map { tool in
            let schema = (try? encoder.encode(tool.schema)).map { String(decoding: $0, as: UTF8.self) } ?? "{}"
            return "- \(tool.name): \(tool.description)\n  Arguments schema: \(schema)"
        }
        return """
            Tools:
            - To call a tool, reply with ONLY one ```\(fenceLanguage) block and nothing else; call at most one tool \
            per reply. Otherwise answer normally.
            - The block holds one strict JSON object with exactly two keys: "tool" (the tool name) and "arguments" \
            (a JSON object matching the tool's arguments schema, {} when it has none). Example:
            ```\(fenceLanguage)
            {"tool": "name", "arguments": {}}
            ```
            - The app answers in the next message: the tool's arguments and output come in data blocks.
            - Only call the tools listed here.
            Available tools:
            \(list.joined(separator: "\n"))
            """
    }

    /// The model's full reply: `.answer` when it holds no ```tool block (one inside another fence does not count),
    /// `.call` for exactly one closed block that is one strict JSON object with exactly the keys `tool` (a name in
    /// `toolNames`) and `arguments` (an object), at most `AISSEParser.maxToolInputBytes`; `.invalid` for anything
    /// else (two or more blocks, an unclosed block, bad JSON, extra keys, an unknown name, non-object arguments).
    /// Text around the one block is tolerated and dropped. `inputJSON` is the arguments re-serialized with sorted
    /// keys, never the raw text. The call gets `id` (the caller's stable local id, such as "text-1").
    public static func parse(_ text: String, toolNames: Set<String>, id: String) -> Reply {
        var bodies: [String] = []
        var lines: [Substring] = []
        var fence = 0
        var isTool = false
        // Real line ends only: U+2028 and the like may sit raw inside a JSON string.
        let isLineEnd = { (character: Character) in character == "\n" || character == "\r\n" || character == "\r" }
        for line in text.split(omittingEmptySubsequences: false, whereSeparator: isLineEnd) {
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            let ticks = trimmed.prefix { $0 == "`" }.count
            if fence > 0 {
                if ticks >= fence, ticks == trimmed.count {
                    if isTool { bodies.append(lines.joined(separator: "\n")) }
                    fence = 0
                    lines = []
                } else if isTool {
                    lines.append(line)
                }
            } else if ticks >= 3 {
                fence = ticks
                isTool = trimmed.dropFirst(ticks).split(separator: " ").first?.lowercased() == fenceLanguage
            }
        }
        if fence > 0, isTool { return .invalid("The tool block was not closed.") }
        guard let body = bodies.first else { return .answer(text) }
        guard bodies.count == 1 else { return .invalid("Call one tool per reply.") }
        guard body.utf8.count <= AISSEParser.maxToolInputBytes else {
            return .invalid("The tool arguments are over 64 KiB.")
        }
        guard let object = try? JSONSerialization.jsonObject(with: Data(body.utf8)) as? [String: Any],
            Set(object.keys) == ["tool", "arguments"]
        else { return .invalid("The tool block must be one JSON object with exactly the keys tool and arguments.") }
        guard let name = object["tool"] as? String, toolNames.contains(name) else {
            return .invalid("That tool is not offered.")
        }
        guard let arguments = object["arguments"] as? [String: Any],
            let inputJSON = AISSEParser.canonicalJSON(arguments)
        else { return .invalid("The tool arguments must be a JSON object.") }
        return .call(AIToolCall(id: id, name: name, inputJSON: inputJSON))
    }

    /// `call` as the fenced block the model writes (one line of sorted-key JSON, so it cannot close the fence);
    /// `parse` reads it back as the same name and arguments.
    public static func callText(_ call: AIToolCall) -> String {
        let arguments = (try? JSONSerialization.jsonObject(with: Data(call.inputJSON.utf8))) as? [String: Any]
        let json = AISSEParser.canonicalJSON(["tool": call.name, "arguments": arguments ?? [:]]) ?? "{}"
        return "```\(fenceLanguage)\n\(json)\n```"
    }

    /// The user text answering one tool call: a fixed app line (the tool name only when it is in `toolNames`, an
    /// app string; "Error" when the result is one), then the arguments and the output as data blocks. `call` is nil
    /// when the result has no known call: then only the output block.
    public static func resultText(
        call: AIToolCall?, result: AIToolResult, toolNames: Set<String>, candidate: () -> String = AIPrompts.randomToken
    ) -> String {
        let tool = call.flatMap { toolNames.contains($0.name) ? "the tool \($0.name)" : nil } ?? "a tool"
        let line = result.isError ? "Error from \(tool) call:" : "Result of \(tool) call:"
        var blocks: [AIDataBlock] = []
        if let call { blocks.append(AIDataBlock(label: .toolArguments, text: call.inputJSON)) }
        blocks.append(AIDataBlock(label: .toolOutput, text: result.content))
        return line + "\n\n" + AIPrompts.dataBlocks(blocks, candidate: candidate)
    }

    /// `messages` with no tool blocks left, for a text-protocol request: a tool call becomes its fenced block
    /// (`callText`) in its message, a tool result becomes `resultText` (its call found by id among the earlier
    /// calls), results first, then the message's own text. Empty messages are dropped and adjacent messages with the
    /// same role merged, so the roles keep alternating as `AIChatHistory.messages` leaves them.
    public static func plainMessages(
        _ messages: [AIChatMessage], toolNames: Set<String>, candidate: () -> String = AIPrompts.randomToken
    ) -> [AIChatMessage] {
        var calls: [String: AIToolCall] = [:]
        var out: [AIChatMessage] = []
        for message in messages {
            var results: [String] = []
            var parts: [String] = []
            for block in message.blocks {
                switch block {
                case .text(let text):
                    if !text.isEmpty { parts.append(text) }
                case .toolUse(let call):
                    calls[call.id] = call
                    parts.append(callText(call))
                case .toolResult(let result):
                    results.append(
                        resultText(call: calls[result.id], result: result, toolNames: toolNames, candidate: candidate))
                }
            }
            let text = (results + parts).joined(separator: "\n\n")
            guard !text.isEmpty else { continue }
            if let last = out.last, last.role == message.role {
                out[out.count - 1] = AIChatMessage(role: message.role, text: last.text + "\n\n" + text)
            } else {
                out.append(AIChatMessage(role: message.role, text: text))
            }
        }
        return out
    }
}
