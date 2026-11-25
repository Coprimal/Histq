// Key and security tests for the chat tool loop (phase 5): it stops at the step limit, stops running tools once the
// turn's output budget is used up, never runs a tool that was not offered, and takes a text-only step without a stop
// for an answer. Fake steps serve events from arrays, so no test reaches a provider. Also the text-tool protocol
// path, and the tool-turn request bodies of both wires (served by the stub `URLProtocol` of `GitHubClientTests`):
// the only automated guard of that contract, since the app's AI stub ignores request bodies.
import Foundation
import HistqCore
import Synchronization
import Testing

struct AIToolLoopTests {
    static let tools = [
        AIToolSpec(
            name: "read_file", description: "Reads a file.",
            schema: .object(["type": .string("object"), "properties": .object(["path": .object(["type": .string("string")])])])),
    ]
    static let names = Set(tools.map(\.name))
    static let request = AIChatRequest(model: "m-1", system: "Be brief.", messages: [AIChatMessage(role: .user, text: "Why?")])

    static func call(_ id: String, name: String = "read_file") -> AIToolCall {
        AIToolCall(id: id, name: name, inputJSON: #"{"path":"a.swift"}"#)
    }

    /// Records what the loop hands its closures; they are `@Sendable`, so the state sits in a `Mutex`.
    final class Probe: Sendable {
        struct State {
            var requests: [AIChatRequest] = []
            var toolRuns: [AIToolCall] = []
            var events: [AIToolLoopEvent] = []
        }
        private let state = Mutex(State())

        var requests: [AIChatRequest] { state.withLock { $0.requests } }
        var toolRuns: [AIToolCall] { state.withLock { $0.toolRuns } }
        var events: [AIToolLoopEvent] { state.withLock { $0.events } }

        /// Runs `loop` on `request`; step N streams `replies(N)`, and a tool run answers `output(call)`.
        func run(
            _ loop: AIToolLoop, request: AIChatRequest = AIToolLoopTests.request,
            replies: @escaping @Sendable (Int) -> [AIStreamEvent],
            output: @escaping @Sendable (AIToolCall) -> String = { _ in "file text" }
        ) async throws -> AIToolLoopOutcome {
            try await loop.run(
                request: request,
                step: { request in
                    let number = self.state.withLock { state in
                        state.requests.append(request)
                        return state.requests.count
                    }
                    return AsyncThrowingStream { continuation in
                        for event in replies(number) { continuation.yield(event) }
                        continuation.finish()
                    }
                },
                runTool: { call in
                    self.state.withLock { $0.toolRuns.append(call) }
                    return AIToolResult(id: call.id, content: output(call), isError: false)
                },
                onEvent: { event in self.state.withLock { $0.events.append(event) } })
        }
    }

    // MARK: - Native loop

    @Test("the loop stops at the step limit: maxSteps requests, tools run in all but the last step")
    func stopsAtTheStepLimit() async throws {
        let probe = Probe()
        let loop = AIToolLoop(tools: Self.tools, nativeTools: true, maxSteps: 3)
        let outcome = try await probe.run(loop) { step in
            [.text("Looking."), .toolCall(Self.call("call-\(step)")), .stop(.toolUse)]
        }

        let note = AIPrompts.toolStepLimit(steps: 3)
        #expect(probe.requests.count == 3)
        #expect(probe.toolRuns.map(\.id) == ["call-1", "call-2"])
        #expect(outcome.stepLimited)
        #expect(outcome.text == "Looking.\n\n" + note)
        #expect(outcome.exchanges.map(\.call.id) == ["call-1", "call-2", "call-3"])
        #expect(outcome.exchanges.last?.result == AIToolResult(id: "call-3", content: AIToolLoop.stepLimited, isError: true))
        #expect(probe.events.contains(.stepLimit(note)))
        #expect(probe.events.last == .finished(outcome.text))
        // Each step after the first carries the earlier calls and their results.
        #expect(probe.requests.map(\.messages.count) == [1, 3, 5])
        #expect(probe.requests.allSatisfy { $0.tools == Self.tools })
    }

    @Test("once the turn's tool output budget is used up, no further tool runs and the overflowing output is not sent")
    func stopsRunningToolsOnceTheBudgetIsUsedUp() async throws {
        let probe = Probe()
        let loop = AIToolLoop(tools: Self.tools, nativeTools: true, outputBudget: 10)
        let outputs = ["a1": "aaaaaa", "a2": "bbbbbb", "a3": "cccccc", "b1": "dddddd"]
        let outcome = try await probe.run(
            loop,
            replies: { step in
                switch step {
                case 1: [.toolCall(Self.call("a1")), .toolCall(Self.call("a2")), .toolCall(Self.call("a3")), .stop(.toolUse)]
                case 2: [.toolCall(Self.call("b1")), .stop(.toolUse)]
                default: [.text("Done."), .stop(.endTurn)]
                }
            },
            output: { outputs[$0.id] ?? "" })

        // a1 fits (6 of 10); a2 runs but would overflow (12), so its output is replaced; a3 and b1 never run.
        #expect(probe.toolRuns.map(\.id) == ["a1", "a2"])
        #expect(outcome.text == "Done.")
        #expect(!outcome.stepLimited)
        #expect(outcome.exchanges.map(\.result.content)
            == ["aaaaaa", AIToolLoop.budgetUsedUp, AIToolLoop.budgetUsedUp, AIToolLoop.budgetUsedUp])
        #expect(outcome.exchanges.map(\.result.isError) == [false, true, true, true])

        #expect(probe.requests.count == 3)
        let results = probe.requests[1].messages.last?.blocks.compactMap { block -> AIToolResult? in
            if case .toolResult(let result) = block { result } else { nil }
        } ?? []
        #expect(results.map(\.id) == ["a1", "a2", "a3"])
        #expect(results.first.map { $0.content.contains("BEGIN DATA ") && $0.content.contains("aaaaaa\nEND DATA ") } == true)
        #expect(results.dropFirst().allSatisfy { $0.content == AIToolLoop.budgetUsedUp && $0.isError })
        for request in probe.requests {
            #expect(!String(describing: request.messages).contains("bbbbbb"), "the overflowing output is never sent")
        }
    }

    @Test("a call to a tool that was not offered is refused without running it")
    func refusesAnUnknownTool() async throws {
        let probe = Probe()
        let loop = AIToolLoop(tools: Self.tools, nativeTools: true)
        let unknown = Self.call("x1", name: "delete_branch")
        let outcome = try await probe.run(loop) { step in
            step == 1 ? [.toolCall(unknown), .stop(.toolUse)] : [.text("Sorry."), .stop(.endTurn)]
        }

        let refusal = AIToolResult(id: "x1", content: AIToolLoop.unknownTool, isError: true)
        #expect(probe.toolRuns.isEmpty)
        #expect(outcome.exchanges == [AIToolExchange(call: unknown, result: refusal)])
        #expect(probe.requests.count == 2)
        #expect(probe.requests[1].messages.last == AIChatMessage(role: .user, blocks: [.toolResult(refusal)]))
        #expect(outcome.text == "Sorry.")
    }

    @Test("a text-only step that ends without a stop is the answer")
    func textOnlyStepWithoutStopIsAnAnswer() async throws {
        let probe = Probe()
        let loop = AIToolLoop(tools: Self.tools, nativeTools: true)
        let outcome = try await probe.run(loop) { _ in [.text("Hel"), .text("lo")] }

        #expect(outcome.text == "Hello" && outcome.exchanges.isEmpty && !outcome.stepLimited)
        #expect(probe.requests.count == 1)
        #expect(probe.events == [.text("Hel"), .text("lo"), .finished("Hello")])
    }

    /// An Anthropic body with one complete tool_use block to `name`, then nothing: no `message_delta`, no
    /// `message_stop`.
    static func anthropicToolBlock(name: String) -> String {
        #"""
        event: content_block_start
        data: {"type":"content_block_start","index":0,"content_block":{"type":"tool_use","id":"call_1","name":"\#(name)","input":{}}}

        event: content_block_delta
        data: {"type":"content_block_delta","index":0,"delta":{"type":"input_json_delta","partial_json":"{\"path\":\"a.swift\"}"}}

        event: content_block_stop
        data: {"type":"content_block_stop","index":0}


        """#
    }

    @Test("a native step whose body ends after a complete tool call with no stop is cut off, and the tool never runs")
    func nativeStepWithoutStopIsCutOff() async throws {
        let stub = StubServer { _ in
            .init(headers: ["Content-Type": "text/event-stream"], body: Self.anthropicToolBlock(name: "read_file"))
        }
        let client = try AIChatClient(provider: .anthropic, apiKey: "sk-test", session: stub.session)
        let runs = Mutex(0)
        let loop = AIToolLoop(tools: Self.tools, nativeTools: true)
        await #expect(throws: AIToolLoopError.cutOff) {
            _ = try await loop.run(
                request: Self.request,
                step: { client.events($0) },
                runTool: { call in
                    runs.withLock { $0 += 1 }
                    return AIToolResult(id: call.id, content: "file text", isError: false)
                },
                onEvent: { _ in })
        }
        #expect(runs.withLock { $0 } == 0)
        #expect(stub.requests.count == 1)
    }

    @Test("through the client, a native call to a tool that was not offered fails the stream")
    func clientRefusesAnUnofferedTool() async throws {
        let stub = StubServer { _ in
            .init(headers: ["Content-Type": "text/event-stream"], body: Self.anthropicToolBlock(name: "delete_branch"))
        }
        let client = try AIChatClient(provider: .anthropic, apiKey: "sk-test", session: stub.session)
        var request = Self.request
        request.tools = Self.tools
        await #expect(throws: AIClientError.invalidResponse("The model called a tool that was not offered.")) {
            for try await _ in client.events(request) {}
        }
    }

    // MARK: - Text-tool protocol

    @Test("parse: an answer, one valid call with sorted-key arguments, an unknown name, two blocks")
    func textProtocolParse() {
        #expect(AITextToolProtocol.parse("Plain answer.", toolNames: Self.names, id: "t") == .answer("Plain answer."))
        let valid = "Sure.\n```tool\n{\"arguments\": {\"b\": 1, \"a\": \"x\"}, \"tool\": \"read_file\"}\n```"
        #expect(AITextToolProtocol.parse(valid, toolNames: Self.names, id: "t")
            == .call(AIToolCall(id: "t", name: "read_file", inputJSON: #"{"a":"x","b":1}"#)))
        let unknown = "```tool\n{\"tool\": \"delete_branch\", \"arguments\": {}}\n```"
        #expect(AITextToolProtocol.parse(unknown, toolNames: Self.names, id: "t") == .invalid("That tool is not offered."))
        let two = "```tool\n{\"tool\": \"read_file\", \"arguments\": {}}\n```\n```tool\n{\"tool\": \"read_file\", \"arguments\": {}}\n```"
        #expect(AITextToolProtocol.parse(two, toolNames: Self.names, id: "t") == .invalid("Call one tool per reply."))
    }

    @Test("the text protocol runs a ```tool block once and sends its result back as text in a data block")
    func textProtocolLoop() async throws {
        let probe = Probe()
        let loop = AIToolLoop(tools: Self.tools, nativeTools: false)
        let outcome = try await probe.run(loop) { step in
            step == 1
                ? [.text("```tool\n{\"tool\": \"read_file\", "), .text("\"arguments\": {\"path\": \"a.swift\"}}\n```")]
                : [.text("It reads a.")]
        }

        let call = AIToolCall(id: "text-1", name: "read_file", inputJSON: #"{"path":"a.swift"}"#)
        #expect(probe.toolRuns == [call])
        #expect(outcome.text == "It reads a.")
        #expect(outcome.exchanges == [AIToolExchange(call: call, result: AIToolResult(id: "text-1", content: "file text", isError: false))])

        let requests = probe.requests
        #expect(requests.count == 2)
        #expect(requests.allSatisfy { $0.tools.isEmpty })
        #expect(requests.allSatisfy { $0.system.contains(AITextToolProtocol.systemSection(tools: Self.tools)) })
        let messages = requests.last?.messages ?? []
        let textOnly = messages.allSatisfy { message in
            message.blocks.allSatisfy { if case .text = $0 { true } else { false } }
        }
        #expect(textOnly, "no native tool blocks in the text protocol")
        #expect(messages.map(\.role) == [.user, .assistant, .user])
        #expect(messages[1].text == AITextToolProtocol.callText(call))
        let result = messages[2].text
        #expect(result.hasPrefix("Result of the tool read_file call:"))
        #expect(result.contains("BEGIN DATA ") && result.contains("file text\nEND DATA "))
    }

    // MARK: - Request bodies (provider contract)

    /// A tool turn: the assistant called a tool, and the user message holds text before the result, so the
    /// Anthropic body must move the result first.
    static let toolTurn = AIChatRequest(
        model: "m-1", system: "Be brief.",
        messages: [
            AIChatMessage(role: .user, text: "Why?"),
            AIChatMessage(role: .assistant, blocks: [.text("Let me look."), .toolUse(call("call_1"))]),
            AIChatMessage(
                role: .user,
                blocks: [.text("Also check b."), .toolResult(AIToolResult(id: "call_1", content: "file text", isError: true))]),
        ],
        tools: tools)

    @Test("the tool-turn request body matches each wire, and a text answer without a finish reason ends the turn",
          arguments: [AIProvider.openAI, .anthropic])
    func toolTurnRequestBody(provider: AIProvider) async throws {
        // A text-only answer with no finish_reason / stop_reason, ended by [DONE] / message_stop.
        let sse = provider == .anthropic
            ? "event: content_block_delta\ndata: {\"type\":\"content_block_delta\",\"index\":0,\"delta\":{\"type\":\"text_delta\",\"text\":\"Hello\"}}\n\nevent: message_stop\ndata: {\"type\":\"message_stop\"}\n\n"
            : AIEndpointTests.sse
        let stub = StubServer { _ in .init(headers: ["Content-Type": "text/event-stream"], body: sse) }
        let client = try AIChatClient(provider: provider, apiKey: "sk-test", session: stub.session)

        var events: [AIStreamEvent] = []
        for try await event in client.events(Self.toolTurn) { events.append(event) }
        #expect(events == [.text("Hello"), .stop(.endTurn)])

        let data = try #require(stub.requests.first?.httpBody)
        let body = try #require(try JSONSerialization.jsonObject(with: data) as? [String: Any])
        let messages = try #require(body["messages"] as? [[String: Any]])
        let tool = try #require((body["tools"] as? [[String: Any]])?.first)

        switch provider.wire {
        case .anthropicMessages:
            #expect(body["system"] as? String == "Be brief.")
            #expect(tool["name"] as? String == "read_file")
            #expect(tool["input_schema"] is [String: Any])
            #expect(messages.count == 3)
            let assistant = try #require(messages[1]["content"] as? [[String: Any]])
            #expect(assistant.map { $0["type"] as? String } == ["text", "tool_use"])
            #expect(assistant[1]["id"] as? String == "call_1")
            #expect(assistant[1]["name"] as? String == "read_file")
            #expect(assistant[1]["input"] as? [String: String] == ["path": "a.swift"])
            #expect(messages[2]["role"] as? String == "user")
            let user = try #require(messages[2]["content"] as? [[String: Any]])
            #expect(user.map { $0["type"] as? String } == ["tool_result", "text"])
            #expect(user[0]["tool_use_id"] as? String == "call_1")
            #expect(user[0]["content"] as? String == "file text")
            #expect(user[0]["is_error"] as? Bool == true)
            #expect(user[1]["text"] as? String == "Also check b.")
        case .chatCompletions:
            #expect(tool["type"] as? String == "function")
            let function = try #require(tool["function"] as? [String: Any])
            #expect(function["name"] as? String == "read_file")
            #expect(function["parameters"] is [String: Any])
            #expect(messages.map { $0["role"] as? String } == ["system", "user", "assistant", "tool", "user"])
            #expect(messages[2]["content"] as? String == "Let me look.")
            let calls = try #require(messages[2]["tool_calls"] as? [[String: Any]])
            #expect(calls.count == 1)
            #expect(calls[0]["id"] as? String == "call_1")
            #expect(calls[0]["type"] as? String == "function")
            let called = try #require(calls[0]["function"] as? [String: Any])
            #expect(called["name"] as? String == "read_file")
            #expect(called["arguments"] as? String == #"{"path":"a.swift"}"#, "arguments go as a JSON string")
            #expect(messages[3]["tool_call_id"] as? String == "call_1")
            #expect(messages[3]["content"] as? String == "file text")
            #expect(messages[4]["content"] as? String == "Also check b.")
        }
    }
}
