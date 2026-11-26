// One line of the AI chat (structure from Dblore's `AIMessageView`): the user's text in a bubble on the right, the
// assistant's on the left, an error in the error tone. The assistant's text is inline Markdown with links stripped
// (`AIResultSheet.markdown`); fenced code blocks are split out into a monospaced box that scrolls sideways, with a
// Copy button. The user's, a tool's and an error's text are shown verbatim: they hold repository names and git's
// messages, which must never turn into Markdown.
import AppKit
import HistqCore
import SwiftUI

struct AIChatMessageView: View {
    let entry: AIChatEntry

    private var isUser: Bool { entry.role == .user }

    var body: some View {
        if entry.role == .tool, let call = entry.toolCall {
            AIChatToolRow(entry: entry, call: call)
        } else if entry.role == .tool {
            Text(verbatim: entry.text)
                .font(.callout)
                .foregroundStyle(.secondary)
                .textSelection(.enabled)
                .frame(maxWidth: .infinity, alignment: .leading)
        } else {
            HStack(spacing: 0) {
                if isUser { Spacer(minLength: 32) }
                bubble
                if !isUser { Spacer(minLength: 32) }
            }
            .frame(maxWidth: .infinity, alignment: isUser ? .trailing : .leading)
        }
    }

    private var bubble: some View {
        content
            .padding(.horizontal, 10)
            .padding(.vertical, 8)
            .background(RoundedRectangle(cornerRadius: 12, style: .continuous)
                .fill(isUser ? Palette.inputSurface : Palette.bgCard))
            .overlay {
                if !isUser || entry.isError {
                    RoundedRectangle(cornerRadius: 12, style: .continuous)
                        .strokeBorder(entry.isError ? AIChatMetrics.errorTone.opacity(0.6) : Palette.surfaceBorder)
                }
            }
    }

    @ViewBuilder
    private var content: some View {
        if entry.isError {
            Label {
                Text(verbatim: entry.text)
            } icon: {
                Image(systemName: "exclamationmark.triangle.fill")
            }
            .foregroundStyle(AIChatMetrics.errorTone)
            .fixedSize(horizontal: false, vertical: true)
            .textSelection(.enabled)
        } else if isUser {
            Text(verbatim: entry.text)
                .fixedSize(horizontal: false, vertical: true)
                .textSelection(.enabled)
        } else if entry.text.allSatisfy(\.isWhitespace) {
            // The model's turn drops an answer that is still blank when it ends, so this shows only while it streams.
            Text("Thinking…")
                .foregroundStyle(.secondary)
        } else {
            VStack(alignment: .leading, spacing: 8) {
                ForEach(Array(AIChatSegment.split(entry.text).enumerated()), id: \.offset) { _, segment in
                    switch segment {
                    case .text(let text): AIChatMarkdownText(text: text)
                    case .code(let language, let code): AIChatCodeBlock(language: language, code: code)
                    }
                }
            }
        }
    }
}

private enum AIChatMetrics {
    /// The tone of `ErrorText`.
    static let errorTone = Color(nsColor: Palette.graphLanes[6])
}

/// A read-only git tool the model ran: one line, "Ran git log -S foo · 3 commits" (or "git_blame failed: …"), that
/// expands on click to the saved output. The call's arguments are model output: shown verbatim, never as Markdown.
private struct AIChatToolRow: View {
    let entry: AIChatEntry
    let call: AIToolCall
    @State private var expanded = false

    var body: some View {
        let title = Self.title(entry, call)
        let output = entry.toolOutput ?? ""
        VStack(alignment: .leading, spacing: 6) {
            Button {
                expanded.toggle()
            } label: {
                HStack(spacing: 6) {
                    Image(systemName: "chevron.right")
                        .font(.system(size: 10, weight: .bold))
                        .rotationEffect(.degrees(expanded ? 90 : 0))
                        .frame(width: 12)
                        .opacity(output.isEmpty ? 0 : 1)
                    Text(verbatim: title)
                        .lineLimit(1)
                        .truncationMode(.middle)
                }
                .font(.callout)
                .foregroundStyle(entry.isError ? AnyShapeStyle(AIChatMetrics.errorTone) : AnyShapeStyle(.secondary))
                .frame(maxWidth: .infinity, alignment: .leading)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .disabled(output.isEmpty)
            .help(title)
            .accessibilityLabel(title)
            .accessibilityValue(expanded ? "Expanded" : "Collapsed")
            if expanded, !output.isEmpty {
                AIChatToolOutput(output: output)
            }
        }
    }

    /// "Ran git log -S foo · 3 commits"; a failed call: "git_blame failed: " and the first line of its error. One line.
    private static func title(_ entry: AIChatEntry, _ call: AIToolCall) -> String {
        let title: String
        if entry.isError {
            let reason = (entry.toolOutput ?? "").split(separator: "\n").first.map(String.init) ?? ""
            title = reason.isEmpty ? entry.text : entry.text + ": " + reason
        } else {
            let summary = entry.text.range(of: " · ").map { String(entry.text[$0.lowerBound...]) } ?? ""
            title = (["Ran", displayName(call.name)] + arguments(call)).joined(separator: " ") + summary
        }
        return title.components(separatedBy: .newlines).joined(separator: " ")
    }

    private static func displayName(_ name: String) -> String {
        name == "read_file" ? "read file" : name.replacingOccurrences(of: "git_", with: "git ")
    }

    /// The call's key arguments, git-style: `-S foo`, a revision, `from..to`, a path, `-L 3,9`.
    private static func arguments(_ call: AIToolCall) -> [String] {
        guard let input = try? JSONDecoder().decode([String: JSONValue].self, from: Data(call.inputJSON.utf8)) else {
            return []
        }
        func value(_ key: String) -> String? {
            switch input[key] {
            case .string(let text)?: text.contains(" ") ? "\"\(text)\"" : text
            case .int(let number)?: String(number)
            default: nil
            }
        }
        func flag(_ name: String, _ key: String) -> String? { value(key).map { "\(name) \($0)" } }
        let lines: String? = value("start_line") == nil && value("end_line") == nil
            ? nil : "-L \(value("start_line") ?? ""),\(value("end_line") ?? "")"
        let parts: [String?] = switch call.name {
        case "git_log": [flag("-S", "search"), flag("-G", "regex"), flag("-n", "max_count"), value("revision"),
                         value("path")]
        case "git_diff": [value("from").map { from in value("to").map { "\(from)..\($0)" } ?? from }, value("path")]
        case "git_blame", "read_file": [lines, value("revision"), value("path")]
        case "git_grep": [input["fixed_strings"] == .bool(true) ? "-F" : nil, value("pattern"), value("revision"),
                          value("path")]
        default: [value("revision"), value("path")]
        }
        return parts.compactMap { $0 }
    }
}

/// A tool's saved output: monospaced, selectable, scrolling sideways; past a few lines it also scrolls down.
private struct AIChatToolOutput: View {
    let output: String

    var body: some View {
        let long = output.utf8.lazy.filter { $0 == UInt8(ascii: "\n") }.count >= 10
        ScrollView(long ? [.horizontal, .vertical] : .horizontal) {
            Text(verbatim: output)
                .font(.callout.monospaced())
                .fixedSize()
                .textSelection(.enabled)
                .padding(8)
        }
        .defaultScrollAnchor(.topLeading)
        .scrollIndicators(.hidden, axes: .horizontal)
        .frame(height: long ? 200 : nil)
        .background(RoundedRectangle(cornerRadius: 8, style: .continuous).fill(Palette.modalInput))
        .overlay(RoundedRectangle(cornerRadius: 8, style: .continuous).strokeBorder(Palette.surfaceBorder))
    }
}

/// A part of an assistant answer: Markdown text, or the body of a ``` fenced block.
private enum AIChatSegment {
    case text(String)
    case code(language: String?, code: String)

    private static let fence = "```"

    /// The parts in order. A fence still open at the end (the answer is streaming) is a code part; blank text parts
    /// are dropped.
    static func split(_ markdown: String) -> [AIChatSegment] {
        var segments: [AIChatSegment] = []
        var lines: [Substring] = []
        var language: String?
        var inCode = false

        func flushText() {
            let text = lines.joined(separator: "\n").trimmingCharacters(in: .whitespacesAndNewlines)
            if !text.isEmpty { segments.append(.text(text)) }
            lines = []
        }

        for line in markdown.split(separator: "\n", omittingEmptySubsequences: false) {
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            if inCode {
                if trimmed == fence {
                    segments.append(.code(language: language, code: lines.joined(separator: "\n")))
                    lines = []
                    inCode = false
                } else {
                    lines.append(line)
                }
            } else if trimmed.hasPrefix(fence) {
                flushText()
                let info = trimmed.dropFirst(fence.count).trimmingCharacters(in: .whitespaces)
                language = info.split(separator: " ").first.map(String.init)
                inCode = true
            } else {
                lines.append(line)
            }
        }
        if inCode {
            segments.append(.code(language: language, code: lines.joined(separator: "\n")))
        } else {
            flushText()
        }
        return segments
    }
}

/// A text part. Its own view, so while the answer streams only the part whose text changed is parsed again.
private struct AIChatMarkdownText: View {
    let text: String

    var body: some View {
        Text(AIResultSheet.markdown(text))
            .fixedSize(horizontal: false, vertical: true)
            .textSelection(.enabled)
    }
}

/// A fenced code block: its language and a Copy button over the code, which scrolls sideways and never wraps.
private struct AIChatCodeBlock: View {
    let language: String?
    let code: String
    @State private var copied = false

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 8) {
                Text(verbatim: language ?? "code")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Spacer(minLength: 0)
                Button(copied ? "Copied" : "Copy", action: copy)
                    .buttonStyle(RowTextButtonStyle())
                    .help("Copy the code")
                    .task(id: copied) {
                        guard copied, (try? await Task.sleep(for: .seconds(1.5))) != nil else { return }
                        copied = false
                    }
            }
            .padding(.horizontal, 8)
            .padding(.vertical, 4)
            Divider()
            ScrollView(.horizontal) {
                Text(verbatim: code)
                    .font(.callout.monospaced())
                    .fixedSize()
                    .textSelection(.enabled)
                    .padding(8)
            }
            .scrollIndicators(.hidden)
        }
        .background(RoundedRectangle(cornerRadius: 8, style: .continuous).fill(Palette.modalInput))
        .overlay(RoundedRectangle(cornerRadius: 8, style: .continuous).strokeBorder(Palette.surfaceBorder))
    }

    private func copy() {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(code, forType: .string)
        copied = true
    }
}
