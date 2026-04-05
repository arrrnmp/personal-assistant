import AppKit
import SwiftUI
import MarkdownUI

// ---------------------------------------------------------------------------
// ViewModel
// ---------------------------------------------------------------------------

@MainActor
final class AssistantViewModel: ObservableObject {
    @Published var messages: [ChatMessage] = []
    @Published var inputText: String = ""
    @Published var isGenerating: Bool = false
    @Published var backendState: BackendStatus.State = .unreachable
    @Published var toolActivity: String? = nil
    @Published var errorMessage: String? = nil

    private let client = BackendClient.shared

    func send() {
        let text = inputText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty, !isGenerating else { return }

        inputText = ""
        errorMessage = nil
        toolActivity = nil

        messages.append(ChatMessage(role: "user", content: text))
        let assistantMessage = ChatMessage(role: "assistant", content: "")
        messages.append(assistantMessage)
        let idx = messages.count - 1

        isGenerating = true

        Task {
            if let status = try? await client.fetchStatus() { backendState = status.state }

            // Only pass user/assistant messages to the backend (not tool intermediates)
            let history = messages.dropLast().filter { $0.role == "user" || $0.role == "assistant" }

            do {
                try await client.chat(
                    messages: Array(history),
                    onToken: { [weak self] token in
                        guard let self else { return }
                        self.messages[idx].content += token
                    },
                    onToolActivity: { [weak self] activity in
                        guard let self else { return }
                        self.toolActivity = activity
                    }
                )
            } catch {
                messages[idx].content = "_\(error.localizedDescription)_"
                errorMessage = error.localizedDescription
            }

            isGenerating = false
            toolActivity = nil
            if let status = try? await client.fetchStatus() { backendState = status.state }
        }
    }

    func refreshState() {
        Task {
            if let status = try? await client.fetchStatus() { backendState = status.state }
        }
    }

    func clear() {
        messages = []
        toolActivity = nil
        errorMessage = nil
    }
}

// ---------------------------------------------------------------------------
// Main view — Liquid Glass layout
// ---------------------------------------------------------------------------

struct AssistantView: View {
    @StateObject private var vm = AssistantViewModel()
    @FocusState private var inputFocused: Bool

    var body: some View {
        VStack(spacing: 0) {
            toolbar
            Divider().opacity(0.3)
            conversation
            Divider().opacity(0.3)
            inputSection
        }
        .glassEffect(in: RoundedRectangle(cornerRadius: 16, style: .continuous))
        .onAppear {
            inputFocused = true
            vm.refreshState()
        }
    }

    // MARK: - Toolbar (drag region)

    private var toolbar: some View {
        HStack(spacing: 10) {
            Image(systemName: "brain")
                .foregroundStyle(.secondary)
            Text("Personal Assistant")
                .font(.headline)
            Spacer()
            stateChip
            Button(action: vm.clear) {
                Image(systemName: "trash")
                    .foregroundStyle(.secondary)
            }
            .buttonStyle(.plain)
            .help("Clear conversation")
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 11)
        .background(
            // Transparent drag area fills the entire toolbar
            WindowDragArea()
        )
    }

    // MARK: - Conversation

    private var conversation: some View {
        ScrollViewReader { proxy in
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 16) {
                    if vm.messages.filter({ $0.role != "tool" }).isEmpty {
                        placeholderView
                    } else {
                        ForEach(vm.messages.filter { $0.role != "tool" }) { msg in
                            MessageBubble(message: msg)
                                .id(msg.id)
                        }
                    }
                }
                .padding(16)
            }
            .onChange(of: vm.messages.last?.content) {
                if let last = vm.messages.last {
                    withAnimation { proxy.scrollTo(last.id, anchor: .bottom) }
                }
            }
        }
    }

    // MARK: - Input

    private var inputSection: some View {
        VStack(spacing: 0) {
            if let activity = vm.toolActivity, vm.isGenerating {
                HStack(spacing: 6) {
                    Image(systemName: "wrench.and.screwdriver.fill")
                    Text(activity)
                        .lineLimit(1)
                        .truncationMode(.tail)
                    Spacer()
                }
                .font(.caption)
                .foregroundStyle(.secondary)
                .padding(.horizontal, 16)
                .padding(.vertical, 8)
            }
            inputBar
        }
    }

    // MARK: - Input bar

    private var inputBar: some View {
        HStack(spacing: 10) {
            TextField("Ask anything…  (⇧↩ for newline)", text: $vm.inputText, axis: .vertical)
                .textFieldStyle(.plain)
                .lineLimit(1...6)
                .focused($inputFocused)
                .onSubmit {
                    if NSApp.currentEvent?.modifierFlags.contains(.shift) == true {
                        vm.inputText += "\n"
                    } else {
                        vm.send()
                    }
                }

            if vm.isGenerating {
                ProgressView().scaleEffect(0.75)
            } else {
                Button(action: vm.send) {
                    Image(systemName: "arrow.up.circle.fill")
                        .font(.title2)
                        .foregroundStyle(
                            vm.inputText.trimmingCharacters(in: .whitespaces).isEmpty
                                ? Color.secondary : Color.accentColor
                        )
                }
                .buttonStyle(.plain)
                .disabled(vm.inputText.trimmingCharacters(in: .whitespaces).isEmpty)
                .keyboardShortcut(.return, modifiers: [])
            }
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 12)
    }

    // MARK: - State chip

    @ViewBuilder
    private var stateChip: some View {
        switch vm.backendState {
        case .modelLoaded(let id):
            let short = id.split(separator: "/").last.map(String.init) ?? id
            Label(short, systemImage: "checkmark.circle.fill")
                .foregroundStyle(.green)
                .chipStyle()
        case .idle:
            Label("No model", systemImage: "exclamationmark.circle")
                .foregroundStyle(.orange)
                .chipStyle()
        case .unreachable:
            Label("LM Studio offline", systemImage: "xmark.circle")
                .foregroundStyle(.red)
                .chipStyle()
        }
    }

    // MARK: - Placeholder

    private var placeholderView: some View {
        VStack(spacing: 10) {
            Image(systemName: "brain")
                .font(.system(size: 44))
                .foregroundStyle(.secondary)
            Text("Ask me anything")
                .font(.title3.weight(.medium))
                .foregroundStyle(.secondary)
            Text("Gemma 4 E4B · LM Studio · running locally")
                .font(.caption)
                .foregroundStyle(.tertiary)
        }
        .frame(maxWidth: .infinity)
        .padding(.top, 60)
    }
}

// ---------------------------------------------------------------------------
// Message bubble — Markdown for assistant, plain text for user
// ---------------------------------------------------------------------------

struct MessageBubble: View {
    let message: ChatMessage
    var isUser: Bool { message.role == "user" }

    var body: some View {
        HStack(alignment: .top) {
            if isUser { Spacer(minLength: 60) }

            if isUser {
                Text(message.content)
                    .textSelection(.enabled)
                    .padding(.horizontal, 13)
                    .padding(.vertical, 9)
                    .background(Color.accentColor)
                    .foregroundStyle(.white)
                    .clipShape(RoundedRectangle(cornerRadius: 16))
            } else {
                VStack(alignment: .leading, spacing: 6) {
                    Markdown(message.content.isEmpty ? "…" : message.content)
                        .markdownTheme(
                            .gitHub.text { BackgroundColor(nil) }
                        )
                        .textSelection(.enabled)
                        .padding(.horizontal, 13)
                        .padding(.vertical, 9)
                        .background(.quinary)
                        .clipShape(RoundedRectangle(cornerRadius: 16))
                        .contentShape(Rectangle())
                        .contextMenu {
                            Button {
                                copyToClipboard()
                            } label: {
                                Label("Copy response", systemImage: "doc.on.doc")
                            }
                        }

                    Button(action: copyToClipboard) {
                        Image(systemName: "doc.on.doc")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                    .buttonStyle(.plain)
                    .help("Copy response")
                    .padding(.leading, 6)
                }
            }

            if !isUser { Spacer(minLength: 60) }
        }
    }

    private func copyToClipboard() {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(message.content, forType: .string)
    }
}

// ---------------------------------------------------------------------------
// Helpers
// ---------------------------------------------------------------------------

extension View {
    func chipStyle() -> some View {
        self.font(.caption)
            .padding(.horizontal, 8)
            .padding(.vertical, 3)
            .background(.quaternary, in: Capsule())
    }
}
