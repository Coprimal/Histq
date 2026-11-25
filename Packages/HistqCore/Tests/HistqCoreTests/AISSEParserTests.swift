// Key feature tests for the SSE parser (task 12.1): the answer text is assembled the same however the network cuts
// the stream into chunks (inside an event, a line, a CRLF or a UTF-8 character), for both wire formats, with CRLF
// line endings, keepalive comments and the end-of-stream event.
import Foundation
import HistqCore
import Testing

struct AISSEParserTests {
    static let chatStream = """
        : keepalive

        data: {"choices":[{"index":0,"delta":{"role":"assistant","content":""}}]}

        data: {"choices":[{"index":0,"delta":{"content":"Fix the "}}]}

        data: {"choices":[{"index":0,"delta":{"content":"café ✓"}}]}

        data: {"choices":[{"index":0,"delta":{},"finish_reason":"stop"}]}

        data: {"choices":[],"usage":{"total_tokens":5}}

        data: [DONE]


        """

    static let anthropicStream = """
        event: message_start
        data: {"type":"message_start","message":{"id":"msg_1","role":"assistant","content":[]}}

        event: content_block_start
        data: {"type":"content_block_start","index":0,"content_block":{"type":"text","text":""}}

        event: ping
        data: {"type": "ping"}

        event: content_block_delta
        data: {"type":"content_block_delta","index":0,"delta":{"type":"text_delta","text":"Fix the "}}

        : keepalive

        event: content_block_delta
        data: {"type":"content_block_delta","index":0,"delta":{"type":"text_delta","text":"café ✓"}}

        event: content_block_stop
        data: {"type":"content_block_stop","index":0}

        event: message_delta
        data: {"type":"message_delta","delta":{"stop_reason":"end_turn"}}

        event: message_stop
        data: {"type":"message_stop"}


        """

    struct StreamCase: Sendable, CustomTestStringConvertible {
        var wire: AIWire
        var payload: String
        var crlf: Bool
        var testDescription: String { "\(wire.rawValue)\(crlf ? " CRLF" : " LF")" }

        var bytes: [UInt8] {
            Array((crlf ? payload.replacingOccurrences(of: "\n", with: "\r\n") : payload).utf8)
        }
    }

    static let cases = [
        StreamCase(wire: .chatCompletions, payload: chatStream, crlf: false),
        StreamCase(wire: .chatCompletions, payload: chatStream, crlf: true),
        StreamCase(wire: .anthropicMessages, payload: anthropicStream, crlf: false),
        StreamCase(wire: .anthropicMessages, payload: anthropicStream, crlf: true),
    ]

    /// Feeds `bytes` cut at `cuts` (sorted offsets), then ends the body; returns the joined text and the deltas.
    /// `toolNames` turns on tool call assembly.
    static func parse(
        _ bytes: [UInt8], wire: AIWire, cuts: [Int], toolNames: Set<String>? = nil
    ) throws -> (text: String, deltas: [AIStreamDelta]) {
        var parser = AISSEParser(wire: wire, toolNames: toolNames)
        var deltas: [AIStreamDelta] = []
        var start = 0
        for cut in cuts + [bytes.count] {
            deltas += try parser.consume(bytes[start..<cut])
            start = cut
        }
        deltas += try parser.finish()
        let text = deltas.reduce(into: "") { text, delta in
            if case .text(let piece) = delta { text += piece }
        }
        return (text, deltas)
    }

    @Test("the text is assembled the same when the stream is cut at any byte, for both wires", arguments: cases)
    func splitAtEveryOffset(_ stream: StreamCase) throws {
        let bytes = stream.bytes
        let whole = try Self.parse(bytes, wire: stream.wire, cuts: [])
        #expect(whole.text == "Fix the café ✓")
        #expect(whole.deltas.last == .done)
        #expect(whole.deltas.filter { $0 == .done }.count == 1)

        for cut in 1..<bytes.count {
            let split = try Self.parse(bytes, wire: stream.wire, cuts: [cut])
            #expect(split.deltas == whole.deltas, "cut at byte \(cut)")
        }
        let byteByByte = try Self.parse(bytes, wire: stream.wire, cuts: Array(1..<bytes.count))
        #expect(byteByByte.deltas == whole.deltas)
    }

    @Test("data: [DONE] ends the stream right where it comes, and an unterminated last event is still dispatched")
    func doneAndUnterminatedEvent() throws {
        let done = try Self.parse(Array("data: {\"choices\":[{\"delta\":{\"content\":\"a\"}}]}\n\ndata: [DONE]\n\n".utf8),
                                  wire: .chatCompletions, cuts: [])
        #expect(done.deltas == [.text("a"), .done])

        let cutOff = try Self.parse(Array("data: {\"choices\":[{\"delta\":{\"content\":\"b\"}}]}".utf8),
                                    wire: .chatCompletions, cuts: [])
        #expect(cutOff.deltas == [.text("b")])
    }

    @Test("an error event in the stream becomes a provider error, on both wires", arguments: [
        (AIWire.chatCompletions, #"data: {"error":{"message":"overloaded"}}"#),
        (AIWire.anthropicMessages, "event: error\n" + #"data: {"type":"error","error":{"type":"overloaded_error","message":"overloaded"}}"#),
    ])
    func errorEvent(wire: AIWire, payload: String) {
        #expect(throws: AIStreamError.provider("overloaded")) {
            _ = try Self.parse(Array((payload + "\n\n").utf8), wire: wire, cuts: [])
        }
    }

    // MARK: - Tool calls (phase 5)

    /// One tool call after some text, its arguments in three pieces with unsorted keys and a multi-byte character; a
    /// later chat fragment's null id and name must not overwrite the first ones.
    static let chatToolStream = #"""
        data: {"choices":[{"index":0,"delta":{"role":"assistant","content":"Let me look."}}]}

        data: {"choices":[{"index":0,"delta":{"tool_calls":[{"index":0,"id":"call_1","type":"function","function":{"name":"read_file","arguments":""}}]}}]}

        data: {"choices":[{"index":0,"delta":{"tool_calls":[{"index":0,"id":null,"function":{"arguments":"{\"pa"}}]}}]}

        : keepalive

        data: {"choices":[{"index":0,"delta":{"tool_calls":[{"index":0,"function":{"name":null,"arguments":"th\":\"café.swift\","}}]}}]}

        data: {"choices":[{"index":0,"delta":{"tool_calls":[{"index":0,"function":{"arguments":"\"line\":3}"}}]}}]}

        data: {"choices":[{"index":0,"delta":{},"finish_reason":"tool_calls"}]}

        data: [DONE]


        """#

    static let anthropicToolStream = #"""
        event: message_start
        data: {"type":"message_start","message":{"id":"msg_1","role":"assistant","content":[]}}

        event: content_block_start
        data: {"type":"content_block_start","index":0,"content_block":{"type":"text","text":""}}

        event: content_block_delta
        data: {"type":"content_block_delta","index":0,"delta":{"type":"text_delta","text":"Let me look."}}

        event: content_block_stop
        data: {"type":"content_block_stop","index":0}

        event: content_block_start
        data: {"type":"content_block_start","index":1,"content_block":{"type":"tool_use","id":"call_1","name":"read_file","input":{}}}

        event: content_block_delta
        data: {"type":"content_block_delta","index":1,"delta":{"type":"input_json_delta","partial_json":"{\"pa"}}

        : keepalive

        event: content_block_delta
        data: {"type":"content_block_delta","index":1,"delta":{"type":"input_json_delta","partial_json":"th\":\"café.swift\","}}

        event: content_block_delta
        data: {"type":"content_block_delta","index":1,"delta":{"type":"input_json_delta","partial_json":"\"line\":3}"}}

        event: content_block_stop
        data: {"type":"content_block_stop","index":1}

        event: message_delta
        data: {"type":"message_delta","delta":{"stop_reason":"tool_use"},"usage":{"output_tokens":20}}

        event: message_stop
        data: {"type":"message_stop"}


        """#

    static let toolNames: Set<String> = ["read_file"]

    static let toolCases = [
        StreamCase(wire: .chatCompletions, payload: chatToolStream, crlf: false),
        StreamCase(wire: .chatCompletions, payload: chatToolStream, crlf: true),
        StreamCase(wire: .anthropicMessages, payload: anthropicToolStream, crlf: false),
        StreamCase(wire: .anthropicMessages, payload: anthropicToolStream, crlf: true),
    ]

    @Test("one tool call assembles the same when the stream is cut at any byte, for both wires", arguments: toolCases)
    func toolCallSplitAtEveryOffset(_ stream: StreamCase) throws {
        let bytes = stream.bytes
        let whole = try Self.parse(bytes, wire: stream.wire, cuts: [], toolNames: Self.toolNames)
        // Sorted keys, re-serialized from the parsed object: never the raw model text.
        let call = AIToolCall(id: "call_1", name: "read_file", inputJSON: #"{"line":3,"path":"café.swift"}"#)
        #expect(whole.deltas == [.text("Let me look."), .toolCall(call), .stop(.toolUse), .done])

        for cut in 1..<bytes.count {
            let split = try Self.parse(bytes, wire: stream.wire, cuts: [cut], toolNames: Self.toolNames)
            #expect(split.deltas == whole.deltas, "cut at byte \(cut)")
        }
        let byteByByte = try Self.parse(
            bytes, wire: stream.wire, cuts: Array(1..<bytes.count), toolNames: Self.toolNames)
        #expect(byteByByte.deltas == whole.deltas)
    }

    /// One SSE event (with its blank line) whose data is `object` as JSON.
    static func event(_ object: [String: Any], name: String? = nil) throws -> [UInt8] {
        let data = String(decoding: try JSONSerialization.data(withJSONObject: object), as: UTF8.self)
        return Array(((name.map { "event: \($0)\n" } ?? "") + "data: \(data)\n\n").utf8)
    }

    /// A tool call to `name` with `input` as its whole arguments: the start (with the arguments) and the end.
    static func toolCallEvents(
        wire: AIWire, name: String = "read_file", input: String
    ) throws -> (start: [UInt8], end: [UInt8]) {
        switch wire {
        case .chatCompletions:
            let fragment: [String: Any] = [
                "index": 0, "id": "call_1", "type": "function",
                "function": ["name": name, "arguments": input] as [String: Any],
            ]
            return (
                try event(["choices": [["index": 0, "delta": ["tool_calls": [fragment]]]]]),
                try event(["choices": [["index": 0, "delta": [String: Any](), "finish_reason": "tool_calls"]]])
            )
        case .anthropicMessages:
            let block: [String: Any] = ["type": "tool_use", "id": "call_1", "name": name, "input": [String: Any]()]
            let delta: [String: Any] = ["type": "input_json_delta", "partial_json": input]
            return (
                try event(["type": "content_block_start", "index": 1, "content_block": block])
                    + event(["type": "content_block_delta", "index": 1, "delta": delta]),
                try event(["type": "content_block_stop", "index": 1])
            )
        }
    }

    @Test("tool arguments over 64 KiB are refused as they arrive, and arguments at the cap are accepted",
          arguments: [AIWire.chatCompletions, .anthropicMessages])
    func oversizedToolInputIsRefused(wire: AIWire) throws {
        // `{"p":"…"}`: 8 bytes around the filler.
        let filler = AISSEParser.maxToolInputBytes - 8
        let atCap = #"{"p":""# + String(repeating: "x", count: filler) + #""}"#
        #expect(atCap.utf8.count == AISSEParser.maxToolInputBytes)
        let accepted = try Self.toolCallEvents(wire: wire, input: atCap)
        let whole = try Self.parse(accepted.start + accepted.end, wire: wire, cuts: [], toolNames: Self.toolNames)
        #expect(whole.deltas.first == .toolCall(AIToolCall(id: "call_1", name: "read_file", inputJSON: atCap)),
                "positive control: a call at the cap assembles")

        let over = #"{"p":""# + String(repeating: "x", count: filler + 1) + #""}"#
        let refused = try Self.toolCallEvents(wire: wire, input: over)
        var parser = AISSEParser(wire: wire, toolNames: Self.toolNames)
        // Refused while the arguments stream in, before the call ends.
        #expect(throws: AIStreamError.invalidToolCall("The model sent tool arguments over 64 KiB.")) {
            _ = try parser.consume(refused.start)
        }
    }

    @Test("a call to a tool that was not offered is refused at its first fragment, for both wires",
          arguments: [AIWire.chatCompletions, .anthropicMessages])
    func unofferedToolIsRefused(wire: AIWire) throws {
        let events = try Self.toolCallEvents(wire: wire, name: "delete_branch", input: "{}")
        var parser = AISSEParser(wire: wire, toolNames: Self.toolNames)
        #expect(throws: AIStreamError.invalidToolCall("The model called a tool that was not offered.")) {
            _ = try parser.consume(events.start)
        }
    }

    @Test("tool arguments that are not a JSON object are refused when the call ends, for both wires",
          arguments: [AIWire.chatCompletions, .anthropicMessages], ["[1]", #""x""#])
    func nonObjectToolInputIsRefused(wire: AIWire, input: String) throws {
        let events = try Self.toolCallEvents(wire: wire, input: input)
        var parser = AISSEParser(wire: wire, toolNames: Self.toolNames)
        #expect(try parser.consume(events.start).isEmpty)
        #expect(throws: AIStreamError.invalidToolCall("The model sent tool arguments that are not a JSON object.")) {
            _ = try parser.consume(events.end)
        }
    }

    @Test("with tools offered, a text-only chat-completions stream ending with [DONE] and no finish_reason is an answer")
    func doneWithoutFinishReasonEndsTheTurn() throws {
        let stream = #"""
            data: {"choices":[{"index":0,"delta":{"content":"Hel"}}]}

            data: {"choices":[{"index":0,"delta":{"content":"lo"}}]}

            data: [DONE]


            """#
        let parsed = try Self.parse(Array(stream.utf8), wire: .chatCompletions, cuts: [], toolNames: Self.toolNames)
        #expect(parsed.deltas == [.text("Hel"), .text("lo"), .stop(.endTurn), .done])
    }
}
