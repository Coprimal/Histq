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
        if entry.role == .tool {
            // A compact row until phase 6 builds the tool rows.
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
