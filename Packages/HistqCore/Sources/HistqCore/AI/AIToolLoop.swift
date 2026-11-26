// The tool loop of one chat turn (ported from Dblore's `AIAssistantViewModel+Tools`): stream a step, run the tools it
// calls, send the results back and continue, at most `maxSteps` requests. Native tool calls when the provider has
// them, else the text-tool protocol (`AITextToolProtocol`), chosen once per turn. The loop does no I/O itself: the
// caller passes the step (a request to its events), the tool runner and an event callback. Tool calls are model
// output and tool output is repository text: untrusted data, sent back in data blocks, never followed.
import Foundation

/// What the loop reports while a turn runs.
public enum AIToolLoopEvent: Sendable, Equatable {
    /// A piece of the current step's text (in the text protocol, a tool block is streamed as text too).
    case text(String)
    /// A call the loop answers next (run or refused).
    case toolCall(AIToolCall)
    /// The answer to `call` (the tool's own output, or a fixed app sentence when refused).
    case toolResult(AIToolCall, AIToolResult)
    /// The turn hit the step limit; the note is app text.
    case stepLimit(String)
    /// The turn ended with this final text.
    case finished(String)
}

/// One tool call of a turn and its answer, for saving.
public struct AIToolExchange: Sendable, Equatable {
    public let call: AIToolCall
    public let result: AIToolResult

    public init(call: AIToolCall, result: AIToolResult) {
        self.call = call
        self.result = result
    }
}

/// How a turn ended.
public struct AIToolLoopOutcome: Sendable, Equatable {
    /// The last step's answer; at the step limit, its text (native only) and the step-limit note.
    public let text: String
    /// Every call of the turn with its answer, in order.
    public let exchanges: [AIToolExchange]
    /// True when the turn stopped at the step limit.
    public let stepLimited: Bool
}

/// Why a turn ended without an answer.
public enum AIToolLoopError: Error, Equatable, Sendable, CustomStringConvertible {
    /// A step streamed a tool call (or was still assembling one) and ended with no stop.
    case cutOff
    /// Two tool calls of the turn have the same id.
    case duplicateCallID

    public var description: String {
        switch self {
        case .cutOff: "The answer ended before its tool call was complete."
        case .duplicateCallID: "The model sent two tool calls with the same id."
        }
    }
}

public struct AIToolLoop: Sendable {
    // The error results the model gets for a call the app does not run (fixed app sentences).
    public static let unknownTool = "That tool is not offered."
    public static let tooManyCalls = "Too many tool calls in one step; this one was not run. Call it again if needed."
    public static let budgetUsedUp = "Tool output budget used up; answer from what you have."
    public static let stepLimited = "The step limit was reached; this call was not run."

    public let tools: [AIToolSpec]
    /// Native tool calls (`AIProvider.supportsNativeTools`), else the text-tool protocol.
    public let nativeTools: Bool
    public let maxSteps: Int
    public let maxCallsPerStep: Int
    /// Characters of tool output one turn sends back in total.
    public let outputBudget: Int

    public init(
        tools: [AIToolSpec], nativeTools: Bool, maxSteps: Int = 10, maxCallsPerStep: Int = 4,
        outputBudget: Int = 4 * AIPrompts.diffBudget
    ) {
        self.tools = tools
        self.nativeTools = nativeTools
        self.maxSteps = max(1, maxSteps)
        self.maxCallsPerStep = maxCallsPerStep
        self.outputBudget = outputBudget
    }

    /// Runs one turn from `request` (its `tools` are replaced by this loop's). Each step streams `step`'s events to
    /// `onEvent` and ends on an answer without tool calls, an error, cancellation (`CancellationError`) or the step
    /// limit: `step` is called at most `maxSteps` times, and the calls of the last step are not run. A step that
    /// streamed a tool call must end with a stop (`AIToolLoopError.cutOff`); a text-only step without one is an
    /// answer. Duplicate call ids end the turn before anything of that step runs.
    public func run(
        request: AIChatRequest,
        step: @Sendable (AIChatRequest) async throws -> AsyncThrowingStream<AIStreamEvent, Error>,
        runTool: @Sendable (AIToolCall) async -> AIToolResult,
        onEvent: @Sendable (AIToolLoopEvent) async -> Void
    ) async throws -> AIToolLoopOutcome {
        let names = Set(tools.map(\.name))
        var current = request
        if nativeTools {
            current.tools = tools
        } else {
            current.tools = []
            current.system += "\n\n" + AITextToolProtocol.systemSection(tools: tools)
            current.messages = AITextToolProtocol.plainMessages(request.messages, toolNames: names)
        }
        var exchanges: [AIToolExchange] = []
        var seen: Set<String> = []
        var used = 0
        var budgetUsedUp = false

        for number in 1...maxSteps {
            try Task.checkCancellation()
            var reply = ""
            var streamed: [AIToolCall] = []
            var stop: AIStopReason?
            for try await event in try await step(current) {
                try Task.checkCancellation()
                switch event {
                case .text(let text):
                    reply += text
                    await onEvent(.text(text))
                case .toolCall(let call):
                    streamed.append(call)
                case .stop(let reason):
                    if stop == nil { stop = reason }
                }
            }
            // A cancelled stream finishes quietly: never take it for an answer.
            try Task.checkCancellation()

            // The calls of the step; `invalid` is the text protocol's refusal of a broken tool block.
            var calls: [AIToolCall] = []
            var invalid: String?
            if nativeTools {
                if !streamed.isEmpty, stop == nil { throw AIToolLoopError.cutOff }
                calls = streamed
            } else {
                switch AITextToolProtocol.parse(reply, toolNames: names, id: "text-\(number)") {
                case .answer: break
                case .call(let call): calls = [call]
                case .invalid(let reason): invalid = reason
                }
            }
            guard !calls.isEmpty || invalid != nil else { return await finish(reply, exchanges, onEvent: onEvent) }
            for call in calls where !seen.insert(call.id).inserted { throw AIToolLoopError.duplicateCallID }

            guard number < maxSteps else {
                for call in calls {
                    await answer(call, error: Self.stepLimited, into: &exchanges, onEvent: onEvent)
                }
                let note = AIPrompts.toolStepLimit(steps: maxSteps)
                await onEvent(.stepLimit(note))
                let kept = nativeTools && !reply.allSatisfy(\.isWhitespace) ? reply + "\n\n" : ""
                return await finish(kept + note, exchanges, stepLimited: true, onEvent: onEvent)
            }

            // Each result as sent: the tool's output in a data block, an app sentence as it is.
            var sent: [AIToolResult] = []
            for (index, call) in calls.enumerated() {
                let refusal: String? =
                    if index >= maxCallsPerStep { Self.tooManyCalls }
                    else if !names.contains(call.name) { Self.unknownTool }
                    else if budgetUsedUp || used >= outputBudget { Self.budgetUsedUp }
                    else { nil }
                if let refusal {
                    let result = await answer(call, error: refusal, into: &exchanges, onEvent: onEvent)
                    sent.append(result)
                    continue
                }
                await onEvent(.toolCall(call))
                let output = await runTool(call)
                try Task.checkCancellation()
                guard used + output.content.count <= outputBudget else {
                    budgetUsedUp = true
                    let result = await answer(
                        call, error: Self.budgetUsedUp, into: &exchanges, announced: true, onEvent: onEvent)
                    sent.append(result)
                    continue
                }
                used += output.content.count
                let result = AIToolResult(id: call.id, content: output.content, isError: output.isError)
                exchanges.append(AIToolExchange(call: call, result: result))
                await onEvent(.toolResult(call, result))
                sent.append(
                    nativeTools
                        ? AIToolResult(
                            id: call.id, content: AIPrompts.toolOutputContent(result.content), isError: result.isError)
                        : result)
            }

            if nativeTools {
                let text: [AIContentBlock] = reply.allSatisfy(\.isWhitespace) ? [] : [.text(reply)]
                current.messages.append(
                    AIChatMessage(role: .assistant, blocks: text + calls.map(AIContentBlock.toolUse)))
                current.messages.append(AIChatMessage(role: .user, blocks: sent.map(AIContentBlock.toolResult)))
            } else if let call = calls.first, let result = sent.first {
                current.messages.append(AIChatMessage(role: .assistant, text: AITextToolProtocol.callText(call)))
                current.messages.append(
                    AIChatMessage(
                        role: .user,
                        text: AITextToolProtocol.resultText(call: call, result: result, toolNames: names)))
            } else if let invalid {
                let result = AIToolResult(id: "text-\(number)", content: invalid, isError: true)
                current.messages.append(AIChatMessage(role: .assistant, text: reply))
                current.messages.append(
                    AIChatMessage(
                        role: .user, text: AITextToolProtocol.resultText(call: nil, result: result, toolNames: names)))
            }
        }
        // Unreachable: the last step returns above.
        return await finish("", exchanges, onEvent: onEvent)
    }

    /// Answers `call` with the error result `error` without running it, and reports it.
    @discardableResult
    private func answer(
        _ call: AIToolCall, error: String, into exchanges: inout [AIToolExchange], announced: Bool = false,
        onEvent: @Sendable (AIToolLoopEvent) async -> Void
    ) async -> AIToolResult {
        if !announced { await onEvent(.toolCall(call)) }
        let result = AIToolResult(id: call.id, content: error, isError: true)
        exchanges.append(AIToolExchange(call: call, result: result))
        await onEvent(.toolResult(call, result))
        return result
    }

    private func finish(
        _ text: String, _ exchanges: [AIToolExchange], stepLimited: Bool = false,
        onEvent: @Sendable (AIToolLoopEvent) async -> Void
    ) async -> AIToolLoopOutcome {
        await onEvent(.finished(text))
        return AIToolLoopOutcome(text: text, exchanges: exchanges, stepLimited: stepLimited)
    }
}
