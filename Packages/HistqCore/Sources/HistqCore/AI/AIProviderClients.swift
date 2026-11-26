// The streaming chat requests of the two wires (ported from Dblore's `OpenAICompatibleClient` and `AnthropicClient`,
// with native tools), and their model list requests. OpenAI, Gemini (through its OpenAI-compatible endpoint), xAI
// and custom servers speak chat-completions; Anthropic speaks Messages. The key goes in a header only, never in the
// URL or the body.
import Foundation

enum AIProviderRequests {
    /// Required by the Messages API (docs.anthropic.com, verified in Dblore 2026-09).
    static let anthropicVersion = "2023-06-01"

    static func make(_ request: AIChatRequest, provider: AIProvider, baseURL: URL, apiKey: String) -> URLRequest {
        switch provider.wire {
        case .chatCompletions: chatCompletions(request, provider: provider, baseURL: baseURL, apiKey: apiKey)
        case .anthropicMessages: anthropicMessages(request, baseURL: baseURL, apiKey: apiKey)
        }
    }

    /// `POST <base>/chat/completions` with `Authorization: Bearer <key>` (no header when a custom server takes no
    /// key).
    static func chatCompletions(
        _ request: AIChatRequest, provider: AIProvider, baseURL: URL, apiKey: String
    ) -> URLRequest {
        var urlRequest = streamingPOST(AIEndpoint.chatURL(base: baseURL, wire: .chatCompletions))
        if !apiKey.isEmpty { urlRequest.setValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization") }
        var messages: [[String: Any]] = []
        if !request.system.isEmpty { messages.append(["role": "system", "content": request.system]) }
        messages += request.messages.flatMap(chatMessages)
        var body: [String: Any] = ["model": request.model, "messages": messages, "stream": true]
        // The hosted providers get no cap: api.openai.com rejects `max_tokens` on o-series and GPT-5+ models, and
        // its replacement, like Gemini's and xAI's output caps, also counts hidden reasoning tokens, so a small cap
        // could be spent on reasoning and return no answer (the model's own limit applies instead). A custom server
        // still gets `max_tokens`, since some local servers default to a very short answer without it.
        if provider == .custom { body["max_tokens"] = request.maxTokens }
        if !request.tools.isEmpty {
            body["tools"] = request.tools.map { tool -> [String: Any] in
                [
                    "type": "function",
                    "function": [
                        "name": tool.name, "description": tool.description, "parameters": jsonObject(tool.schema),
                    ] as [String: Any],
                ]
            }
        }
        urlRequest.httpBody = try? JSONSerialization.data(withJSONObject: body)
        return urlRequest
    }

    /// `POST <base>/messages` with `x-api-key` and `anthropic-version`; `max_tokens` is required there.
    static func anthropicMessages(_ request: AIChatRequest, baseURL: URL, apiKey: String) -> URLRequest {
        var urlRequest = streamingPOST(AIEndpoint.chatURL(base: baseURL, wire: .anthropicMessages))
        urlRequest.setValue(apiKey, forHTTPHeaderField: "x-api-key")
        urlRequest.setValue(anthropicVersion, forHTTPHeaderField: "anthropic-version")
        var body: [String: Any] = [
            "model": request.model,
            "messages": request.messages.map(anthropicMessage),
            "max_tokens": request.maxTokens,
            "stream": true,
        ]
        if !request.system.isEmpty { body["system"] = request.system }
        if !request.tools.isEmpty {
            body["tools"] = request.tools.map {
                ["name": $0.name, "description": $0.description, "input_schema": jsonObject($0.schema)] as [String: Any]
            }
        }
        urlRequest.httpBody = try? JSONSerialization.data(withJSONObject: body)
        return urlRequest
    }

    /// A text-only message stays one `{role, content}` message. Each tool result becomes its own `role: "tool"`
    /// message (by `tool_call_id`), followed by any user text; an assistant turn with tool uses carries `tool_calls`
    /// with the arguments as a JSON string, and its text or `null` as `content`.
    private static func chatMessages(_ message: AIChatMessage) -> [[String: Any]] {
        guard hasToolBlocks(message) else { return [["role": message.role.rawValue, "content": message.text]] }
        var messages: [[String: Any]] = []
        var calls: [[String: Any]] = []
        for block in message.blocks {
            switch block {
            case .text: break
            case .toolUse(let call):
                calls.append([
                    "id": call.id, "type": "function",
                    "function": ["name": call.name, "arguments": call.inputJSON],
                ])
            case .toolResult(let result):
                messages.append(["role": "tool", "tool_call_id": result.id, "content": result.content])
            }
        }
        let text = message.text
        if !calls.isEmpty {
            messages.append([
                "role": message.role.rawValue, "content": text.isEmpty ? NSNull() : text, "tool_calls": calls,
            ])
        } else if !text.isEmpty {
            messages.append(["role": message.role.rawValue, "content": text])
        }
        return messages
    }

    /// A text-only message keeps a string `content`; one with tool blocks sends a block array, `tool_result` blocks
    /// first as the Messages API requires, and no empty text block (the API refuses one).
    private static func anthropicMessage(_ message: AIChatMessage) -> [String: Any] {
        guard hasToolBlocks(message) else { return ["role": message.role.rawValue, "content": message.text] }
        let results = message.blocks.filter { if case .toolResult = $0 { true } else { false } }
        let others = message.blocks.filter { if case .toolResult = $0 { false } else { true } }
        let content = (results + others).compactMap { block -> [String: Any]? in
            switch block {
            case .text(let text):
                return text.isEmpty ? nil : ["type": "text", "text": text]
            case .toolUse(let call):
                // `inputJSON` is the canonical object the parser validated; one that does not parse back is dropped
                // rather than sent as a different call.
                guard let input = try? JSONSerialization.jsonObject(with: Data(call.inputJSON.utf8)) as? [String: Any]
                else { return nil }
                return ["type": "tool_use", "id": call.id, "name": call.name, "input": input]
            case .toolResult(let result):
                var object: [String: Any] = ["type": "tool_result", "tool_use_id": result.id, "content": result.content]
                if result.isError { object["is_error"] = true }
                return object
            }
        }
        return ["role": message.role.rawValue, "content": content]
    }

    private static func hasToolBlocks(_ message: AIChatMessage) -> Bool {
        message.blocks.contains { if case .text = $0 { false } else { true } }
    }

    /// `value` as the Foundation object `JSONSerialization` writes.
    private static func jsonObject(_ value: JSONValue) -> Any {
        switch value {
        case .null: NSNull()
        case .bool(let value): value
        case .int(let value): value
        case .double(let value): value
        case .string(let value): value
        case .array(let values): values.map(jsonObject)
        case .object(let values): values.mapValues(jsonObject)
        }
    }

    /// The longest a model list request waits.
    static let modelListTimeout: TimeInterval = 15

    /// `GET <base>/models` (Anthropic: `?limit=1000`, its page size is 20 by default) with the same key headers as
    /// the chat request. Every base already ends in its version path (`/v1`, `/v1beta/openai`), so none is added.
    static func modelList(provider: AIProvider, baseURL: URL, apiKey: String) -> URLRequest {
        var url = baseURL.appendingPathComponent("models")
        if provider.wire == .anthropicMessages { url.append(queryItems: [URLQueryItem(name: "limit", value: "1000")]) }
        var request = URLRequest(url: url, timeoutInterval: modelListTimeout)
        request.httpMethod = "GET"
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        switch provider.wire {
        case .chatCompletions:
            if !apiKey.isEmpty { request.setValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization") }
        case .anthropicMessages:
            request.setValue(apiKey, forHTTPHeaderField: "x-api-key")
            request.setValue(anthropicVersion, forHTTPHeaderField: "anthropic-version")
        }
        return request
    }

    private static func streamingPOST(_ url: URL) -> URLRequest {
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue("text/event-stream", forHTTPHeaderField: "Accept")
        return request
    }
}

/// Reads a provider's model list. The answer is untrusted: an id that could not be a model id (empty, over 200
/// characters, or holding control characters) is dropped, and the list is capped.
public enum AIModelList {
    /// The most ids kept.
    public static let maxModels = 2000
    /// The longest id kept, in characters.
    public static let maxIDLength = 200

    /// The ids of `{"data": [{"id": …}]}` (OpenAI-compatible and Anthropic) or `{"models": [{"name": …}]}`, without
    /// a leading `models/` (Gemini), deduplicated, sorted ascending and capped at `maxModels`. Throws
    /// `AIClientError.invalidResponse` when the body is not such a list.
    public static func parse(_ data: Data) throws -> [String] {
        guard let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw AIClientError.invalidResponse("the model list is not JSON")
        }
        let raw: [String]
        if let entries = object["data"] as? [Any] {
            raw = entries.compactMap { ($0 as? [String: Any])?["id"] as? String }
        } else if let entries = object["models"] as? [Any] {
            raw = entries.compactMap { ($0 as? [String: Any])?["name"] as? String }
        } else {
            throw AIClientError.invalidResponse("the answer has no model list")
        }
        let ids = raw.map { $0.hasPrefix("models/") ? String($0.dropFirst("models/".count)) : $0 }
            .filter(isUsableID)
        return Array(Set(ids).sorted().prefix(maxModels))
    }

    private static func isUsableID(_ id: String) -> Bool {
        !id.isEmpty && id.count <= maxIDLength
            && !id.unicodeScalars.contains(where: CharacterSet.controlCharacters.contains)
    }
}
