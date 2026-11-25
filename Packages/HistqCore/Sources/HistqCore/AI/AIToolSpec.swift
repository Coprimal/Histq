// Provider-agnostic tool definitions, tool calls and tool results for the AI chat (ported from Dblore's
// `AIToolSpec`). Tool calls and their input are model output: untrusted data, never instructions.
import Foundation

/// A tool offered to the model. `schema` is the JSON Schema of its arguments.
public struct AIToolSpec: Sendable, Equatable {
    public let name: String
    public let description: String
    public let schema: JSONValue

    public init(name: String, description: String, schema: JSONValue) {
        self.name = name
        self.description = description
        self.schema = schema
    }
}

/// A tool call from the model. `inputJSON` is the validated arguments object re-serialized with sorted keys (never
/// the raw model text); it is still untrusted model output. No provider echo field: Gemini uses the text-tool
/// protocol (phase 5, 5.1 finding).
public struct AIToolCall: Sendable, Equatable {
    public let id: String
    public let name: String
    public let inputJSON: String

    public init(id: String, name: String, inputJSON: String) {
        self.id = id
        self.name = name
        self.inputJSON = inputJSON
    }
}

/// The app's answer to the tool call with the same `id`.
public struct AIToolResult: Sendable, Equatable {
    public let id: String
    public let content: String
    public let isError: Bool

    public init(id: String, content: String, isError: Bool) {
        self.id = id
        self.content = content
        self.isError = isError
    }
}
