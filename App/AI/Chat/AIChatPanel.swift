// The AI chat card (structure from Dblore's `AIAssistantPanel`): a header (title, Settings › AI, the saved chats,
// New Chat, Collapse), the body (set up a provider, the empty chat, or the messages, kept scrolled to the bottom) and
// the attached references (removable chips) with the quick actions they offer (each sends at once in a new chat),
// and the composer (Return sends, Shift+Return adds a line, an IME composition never sends; Stop while an answer
// streams). It fills the frame its container gives it. Header, messages and composer are their own views, so a
// keystroke or a streamed piece redraws only the part that reads it.
import AppKit
import HistqCore
import SwiftUI

struct AIChatPanel: View {
    @Bindable var model: AIChatModel
    /// Opens Settings › AI (`WindowModel.selectSettings(.ai)`).
    let onOpenSettings: () -> Void
    @FocusState private var composerFocused: Bool

    private var setup: AISetup { .shared }

    var body: some View {
        VStack(spacing: 0) {
            AIChatHeader(model: model, onOpenSettings: onOpenSettings, composerFocused: $composerFocused)
            Divider()
            content
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            Divider()
            AIChatAttachments(model: model)
            AIChatComposer(model: model, composerFocused: $composerFocused)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .clipShape(RoundedRectangle(cornerRadius: AIChatPanelMetrics.cornerRadius, style: .continuous))
        .modifier(GlassCard(cornerRadius: AIChatPanelMetrics.cornerRadius))
        .environment(\.cardSurface, Palette.sheetCard)
        .environment(\.cardBorder, Palette.sheetCardBorder)
        .onAppear { setup.loadKeysIfNeeded() }
    }

    @ViewBuilder
    private var content: some View {
        if setup.isReady {
            if model.entries.isEmpty {
                emptyState
            } else {
                AIChatMessageList(model: model)
            }
        } else if !setup.keysLoaded {
            // The Keychain read is still running: neither the set-up card nor the chat yet.
            DelayedSpinner(detail: "ai chat keys")
        } else {
            setupState
        }
    }

    private var setupState: some View {
        VStack(spacing: 12) {
            Image(systemName: "sparkles")
                .font(.title2)
                .foregroundStyle(.secondary)
            Text("Set up an AI provider to chat about this repository.")
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
            Button("Set up a provider", action: onOpenSettings)
                .buttonStyle(RowTextButtonStyle(formRow: true, prominent: true))
                .help("Open Settings › AI")
        }
        .padding(20)
    }

    private var emptyState: some View {
        Text("Ask about this repository, or use Explain on a commit or on your changes.")
            .foregroundStyle(.secondary)
            .multilineTextAlignment(.center)
            .padding(20)
    }
}

private enum AIChatPanelMetrics {
    /// A raised card's radius (`GlassCard`): the card floats over the graph.
    static let cornerRadius: CGFloat = 20
    /// The composer grows to this many lines (about 110 pt), then scrolls.
    static let composerMaxLines = 6
    static let bottomID = "ai-chat-bottom"
}

// MARK: - Header

private struct AIChatHeader: View {
    let model: AIChatModel
    let onOpenSettings: () -> Void
    var composerFocused: FocusState<Bool>.Binding
    @State private var showsHistory = false

    var body: some View {
        HStack(spacing: 14) {
            HStack(spacing: 6) {
                Image("histq-logo")
                    .resizable()
                    .scaledToFit()
                    .frame(width: 16, height: 16)
                    .accessibilityHidden(true)
                Text("AI Chat")
                    .font(.body.weight(.semibold))
                    .lineLimit(1)
            }
            .accessibilityElement(children: .combine)
            .accessibilityAddTraits(.isHeader)
            Spacer(minLength: 0)
            iconButton("gearshape", help: "AI settings", action: onOpenSettings)
            iconButton("clock.arrow.circlepath", help: "Chat history") {
                if !showsHistory { model.loadConversations() }
                showsHistory.toggle()
            }
            .popover(isPresented: $showsHistory, arrowEdge: .bottom) {
                AIChatHistoryList(model: model, isPresented: $showsHistory) { composerFocused.wrappedValue = true }
            }
            iconButton("square.and.pencil", help: "New chat") {
                model.newChat()
                composerFocused.wrappedValue = true
            }
            .disabled(model.entries.isEmpty)
            iconButton("chevron.down", help: "Collapse") { model.isExpanded = false }
        }
        .padding(.horizontal, 14)
        .frame(height: SectionCardMetrics.headerHeight + 4)
    }

    private func iconButton(_ systemImage: String, help: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: systemImage)
                .foregroundStyle(.secondary)
        }
        .buttonStyle(RowIconButtonStyle())
        .help(help)
        .accessibilityLabel(help)
    }
}

// MARK: - History

/// The saved chats, newest first: a click opens one, the trash deletes it. A placeholder until the list is read.
private struct AIChatHistoryList: View {
    let model: AIChatModel
    @Binding var isPresented: Bool
    let onOpen: () -> Void
    @AppStorage(PrefKey.dateFormat.rawValue, store: Preferences.defaults) private var dateFormat = "MM/dd/yy @ HH:mm"

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Chat history")
                .font(.callout)
                .foregroundStyle(.secondary)
                .padding(.horizontal, 8)
            if !model.conversationsLoaded {
                placeholder
            } else if model.conversations.isEmpty {
                Text("No saved chats yet")
                    .foregroundStyle(.secondary)
                    .padding(.horizontal, 8)
                    .padding(.bottom, 4)
            } else {
                list
            }
        }
        .padding(10)
        .frame(width: 300)
    }

    private var placeholder: some View {
        VStack(alignment: .leading, spacing: 12) {
            ForEach([0.8, 0.6, 0.7], id: \.self) { fraction in
                SkeletonLine(fraction: fraction, height: 12)
            }
        }
        .padding(8)
        .overlay { DelayedSpinner(detail: "ai chat history") }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("Loading saved chats")
    }

    private var list: some View {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: Locale.current.identifier)
        formatter.dateFormat = dateFormat
        return ScrollView {
            VStack(spacing: 2) {
                ForEach(model.conversations) { conversation in
                    AIChatHistoryRow(
                        conversation: conversation, date: formatter.string(from: conversation.updatedAt),
                        isCurrent: conversation.id == model.conversationID,
                        onOpen: {
                            model.open(id: conversation.id)
                            isPresented = false
                            onOpen()
                        },
                        onDelete: { model.delete(id: conversation.id) })
                }
            }
        }
        .scrollBounceBehavior(.basedOnSize)
        .frame(maxHeight: 360)
        .fixedSize(horizontal: false, vertical: true)
    }
}

private struct AIChatHistoryRow: View {
    let conversation: AIChatModel.Summary
    let date: String
    let isCurrent: Bool
    let onOpen: () -> Void
    let onDelete: () -> Void
    @State private var hovered = false

    private var title: String { conversation.title.isEmpty ? "Untitled chat" : conversation.title }

    var body: some View {
        HStack(spacing: 8) {
            Button(action: onOpen) {
                VStack(alignment: .leading, spacing: 2) {
                    Text(verbatim: title)
                        .lineLimit(1)
                        .truncationMode(.tail)
                    Text(verbatim: date)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityLabel(title)
            Button(action: onDelete) {
                Image(systemName: "trash")
                    .foregroundStyle(.secondary)
            }
            .buttonStyle(RowIconButtonStyle())
            .opacity(hovered ? 1 : 0)
            .help("Delete chat")
            .accessibilityLabel("Delete chat \(title)")
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 5)
        .background(RoundedRectangle(cornerRadius: 8, style: .continuous)
            .fill(isCurrent ? Palette.selectedFill : hovered ? Palette.hoverFill : .clear))
        .animation(Motion.hover, value: hovered)
        .onHover { hovered = $0 }
    }
}

// MARK: - Messages

/// The conversation, kept scrolled to its end as entries come and as the answer streams.
private struct AIChatMessageList: View {
    let model: AIChatModel

    var body: some View {
        ScrollViewReader { proxy in
            ScrollView {
                LazyVStack(spacing: 10) {
                    ForEach(model.entries) { entry in
                        AIChatMessageView(entry: entry, onThinking: model.logPlaceholder)
                    }
                    Color.clear
                        .frame(height: 1)
                        .id(AIChatPanelMetrics.bottomID)
                }
                .padding(12)
            }
            .onAppear { proxy.scrollTo(AIChatPanelMetrics.bottomID, anchor: .bottom) }
            .onChange(of: model.entries.count) { _, _ in
                proxy.scrollTo(AIChatPanelMetrics.bottomID, anchor: .bottom)
            }
            .onChange(of: model.entries.last?.text) { _, _ in
                proxy.scrollTo(AIChatPanelMetrics.bottomID, anchor: .bottom)
            }
        }
    }
}

// MARK: - Attachments

/// The references attached to the next message, each with an x, and the quick actions they offer. Each row scrolls
/// sideways, so many chips never grow the card.
private struct AIChatAttachments: View {
    let model: AIChatModel

    var body: some View {
        if !model.attachments.isEmpty {
            VStack(alignment: .leading, spacing: 6) {
                row {
                    ForEach(model.attachments, id: \.self) { reference in
                        AIChatReferenceChip(label: reference.label) { model.detach(reference) }
                    }
                }
                let actions = model.quickActions
                if !actions.isEmpty {
                    row {
                        ForEach(actions, id: \.self) { action in
                            Button(action.label) { model.runQuickAction(action) }
                                .font(.caption)
                                .buttonStyle(RaisedButtonStyle(height: 22, horizontalPadding: 10))
                                .disabled(!AISetup.shared.isReady)
                                .help("Ask in a new chat about the attached changes")
                        }
                    }
                }
            }
            .padding(.horizontal, 10)
            .padding(.top, 8)
        }
    }

    private func row(@ViewBuilder _ content: () -> some View) -> some View {
        ScrollView(.horizontal) {
            HStack(spacing: 6, content: content)
        }
        .scrollIndicators(.hidden)
        .scrollBounceBehavior(.basedOnSize)
    }
}

/// One attached reference: its label (UI only) and an x that removes it.
private struct AIChatReferenceChip: View {
    let label: String
    let onRemove: () -> Void

    var body: some View {
        HStack(spacing: 4) {
            Text(verbatim: label)
                .font(.caption)
                .lineLimit(1)
                .truncationMode(.middle)
                .frame(maxWidth: 200, alignment: .leading)
            Button(action: onRemove) {
                Image(systemName: "xmark")
                    .font(.caption2.weight(.semibold))
                    .foregroundStyle(.secondary)
                    .frame(width: 14, height: 14)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .help("Remove")
            .accessibilityLabel("Remove \(label)")
        }
        .padding(.leading, 9)
        .padding(.trailing, 5)
        .frame(height: 22)
        .background(Capsule().fill(Palette.tabFill))
        .help(label)
    }
}

// MARK: - Composer

private struct AIChatComposer: View {
    @Bindable var model: AIChatModel
    var composerFocused: FocusState<Bool>.Binding
    @Environment(\.tabIsShown) private var tabIsShown

    private var isReady: Bool { AISetup.shared.isReady }

    /// An input method is composing in the field: Return confirms it, never sends.
    private static var isComposing: Bool {
        (NSApp.keyWindow?.firstResponder as? NSTextView)?.hasMarkedText() == true
    }

    var body: some View {
        HStack(alignment: .bottom, spacing: 8) {
            field
            if model.isGenerating {
                Button(action: model.stop) {
                    Image(systemName: "stop.fill")
                }
                .buttonStyle(RowTextButtonStyle(formRow: true, circle: true))
                .padding(.bottom, 3)
                .help("Stop")
                .accessibilityLabel("Stop")
            } else {
                Button(action: send) {
                    Image(systemName: "arrow.up")
                }
                .buttonStyle(RowTextButtonStyle(formRow: true, circle: true, prominent: true))
                .padding(.bottom, 3)
                .disabled(!isReady || model.draft.allSatisfy(\.isWhitespace))
                .help("Send (Return). New line (Shift+Return)")
                .accessibilityLabel("Send")
            }
        }
        .padding(10)
        .onAppear(perform: focus)
        .onChange(of: model.isExpanded) { _, expanded in
            if expanded { focus() }
        }
    }

    @ViewBuilder
    private var field: some View {
        // Unmounted in a kept-alive tab that is not shown, out of the key view loop (`settingsTextEditor`).
        if tabIsShown {
            TextField("Ask about this repository", text: $model.draft, axis: .vertical)
                .textFieldStyle(.plain)
                .lineLimit(1...AIChatPanelMetrics.composerMaxLines)
                .focused(composerFocused)
                .disabled(!isReady)
                .onKeyPress(.return, phases: .down) { press in
                    guard !Self.isComposing else { return .ignored }
                    if press.modifiers.contains(.shift) {
                        insertNewline()
                    } else {
                        send()
                    }
                    return .handled
                }
                .padding(.horizontal, 10)
                .padding(.vertical, 7)
                .modifier(SettingsInputChrome(focused: composerFocused.wrappedValue))
        } else {
            Color.clear.frame(height: 30)
        }
    }

    private func send() {
        guard isReady else { return }
        model.send()
    }

    /// Shift+Return: the field inserts no line itself, so one goes in at the caret.
    private func insertNewline() {
        guard let textView = NSApp.keyWindow?.firstResponder as? NSTextView else {
            model.draft.append("\n")
            return
        }
        textView.insertText("\n", replacementRange: textView.selectedRange())
    }

    private func focus() {
        guard tabIsShown else { return }
        DispatchQueue.main.async { composerFocused.wrappedValue = true }
    }
}
