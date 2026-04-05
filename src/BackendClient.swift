import Foundation

// ---------------------------------------------------------------------------
// Models
// ---------------------------------------------------------------------------

struct ChatMessage: Codable, Identifiable {
    let id: UUID
    var role: String       // "user" | "assistant" | "tool"
    var content: String
    var toolCallId: String?
    var toolCalls: [ToolCall]?

    init(role: String, content: String, toolCallId: String? = nil, toolCalls: [ToolCall]? = nil) {
        self.id = UUID()
        self.role = role
        self.content = content
        self.toolCallId = toolCallId
        self.toolCalls = toolCalls
    }
}

struct ToolCall: Codable {
    let id: String
    let type: String
    struct Function: Codable { let name: String; let arguments: String }
    let function: Function
}

struct BackendStatus {
    enum State { case unreachable, idle, modelLoaded(String) }
    let state: State
}

enum BackendError: LocalizedError {
    case noModelLoaded
    case serverUnreachable

    var errorDescription: String? {
        switch self {
        case .noModelLoaded:     return "No model loaded in LM Studio. Load a model and try again."
        case .serverUnreachable: return "LM Studio is not running. Start it and enable the local server."
        }
    }
}

// ---------------------------------------------------------------------------
// Client
// ---------------------------------------------------------------------------

@MainActor
final class BackendClient: ObservableObject {
    static let shared = BackendClient()

    var port: Int = 1234
    var systemPrompt: String = """
    You are a helpful personal assistant.
    Keep responses concise, sharp, and actionable.
    Use a friendly tone with light emoji use (0-2 when helpful, never spammy).
    Prefer clear bullets for multi-step guidance.
    """

    private var baseURL: URL { URL(string: "http://127.0.0.1:\(port)")! }
    private let builtins = BuiltinToolRegistry.shared
    private let mcp = MCPManager.shared

    // MARK: - Status

    func fetchStatus() async throws -> BackendStatus {
        let url = baseURL.appending(path: "/v1/models")
        var req = URLRequest(url: url, timeoutInterval: 3)
        req.httpMethod = "GET"

        guard let (data, resp) = try? await URLSession.shared.data(for: req),
              (resp as? HTTPURLResponse)?.statusCode == 200 else {
            return BackendStatus(state: .unreachable)
        }

        struct ModelsResponse: Decodable {
            struct Model: Decodable { let id: String }
            let data: [Model]
        }
        if let models = try? JSONDecoder().decode(ModelsResponse.self, from: data),
           let first = models.data.first {
            return BackendStatus(state: .modelLoaded(first.id))
        }
        return BackendStatus(state: .idle)
    }

    // MARK: - Chat with streaming tool-calling loop

    func chat(
        messages: [ChatMessage],
        onToken: @escaping (String) -> Void,
        onToolActivity: @escaping (String?) -> Void = { _ in }
    ) async throws {
        defer { onToolActivity(nil) }

        let status = try await fetchStatus()
        let modelID: String
        switch status.state {
        case .modelLoaded(let id): modelID = id
        case .idle:                throw BackendError.noModelLoaded
        case .unreachable:         throw BackendError.serverUnreachable
        }

        let systemMessage = ChatMessage(role: "system", content: systemPrompt)
        var history = [systemMessage] + messages
        let allTools = builtins.definitions + mcp.toolDefinitions

        // Stream every turn and collect tool_calls from delta chunks.
        while true {
            var collectedCalls: [Int: (id: String, name: String, args: String)] = [:]
            var streamedAssistantText = ""

            let body = buildPayload(model: modelID, messages: history, tools: allTools, stream: true)
            var req = URLRequest(url: baseURL.appending(path: "/v1/chat/completions"))
            req.httpMethod = "POST"
            req.setValue("application/json", forHTTPHeaderField: "Content-Type")
            req.httpBody = try JSONSerialization.data(withJSONObject: body)

            let (bytes, response) = try await URLSession.shared.bytes(for: req)
            guard (response as? HTTPURLResponse)?.statusCode == 200 else {
                throw URLError(.badServerResponse)
            }

            for try await line in bytes.lines {
                guard line.hasPrefix("data: ") else { continue }
                let payload = String(line.dropFirst(6))
                if payload == "[DONE]" { break }
                guard let data = payload.data(using: .utf8),
                      let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                       let choices = obj["choices"] as? [[String: Any]],
                       let choice = choices.first else { continue }

                guard let delta = choice["delta"] as? [String: Any] else { continue }

                // Regular content token — stream immediately
                if let text = delta["content"] as? String, !text.isEmpty {
                    streamedAssistantText += text
                    onToken(text)
                }

                // Tool call deltas — accumulate by index
                if let tcChunks = delta["tool_calls"] as? [[String: Any]] {
                    for chunk in tcChunks {
                        guard let idx = chunk["index"] as? Int else { continue }
                        let fn = chunk["function"] as? [String: Any]
                        let id  = chunk["id"]   as? String ?? collectedCalls[idx]?.id   ?? ""
                        let name = fn?["name"]  as? String ?? collectedCalls[idx]?.name ?? ""
                        let argChunk = fn?["arguments"] as? String ?? ""
                        let prevArgs = collectedCalls[idx]?.args ?? ""
                        collectedCalls[idx] = (id: id, name: name, args: prevArgs + argChunk)
                    }
                }
            }

            // If the model requested tools, execute them and loop.
            // We key off collected tool_calls directly, since some backends omit
            // finish_reason in intermediate chunks.
            if !collectedCalls.isEmpty {
                let toolCalls = collectedCalls.sorted { $0.key < $1.key }.map { (_, v) in
                    ToolCall(id: v.id, type: "function", function: .init(name: v.name, arguments: v.args))
                }
                let toolNames = toolCalls.map(\.function.name).joined(separator: ", ")
                onToolActivity("Calling tools: \(toolNames)")
                history.append(ChatMessage(role: "assistant", content: streamedAssistantText, toolCalls: toolCalls))

                for call in toolCalls {
                    onToolActivity("Running \(call.function.name)…")
                    let args = (try? JSONSerialization.jsonObject(
                        with: Data(call.function.arguments.utf8)) as? [String: Any]) ?? [:]
                    let result: String
                    do {
                        if builtins.canHandle(call.function.name) {
                            result = try await builtins.execute(name: call.function.name, arguments: args)
                        } else if mcp.canHandle(call.function.name) {
                            result = try await mcp.callTool(name: call.function.name, arguments: args)
                        } else {
                            result = "Unknown tool: \(call.function.name)"
                        }
                    } catch {
                        result = "Tool error: \(error.localizedDescription)"
                    }
                    history.append(ChatMessage(role: "tool", content: result, toolCallId: call.id))
                }
                onToolActivity("Tool run complete")
                continue
            }

            onToolActivity(nil)
            break  // finish_reason == "stop" — we're done
        }
    }

    // MARK: - Payload builder

    private func buildPayload(
        model: String,
        messages: [ChatMessage],
        tools: [ToolDefinition],
        stream: Bool
    ) -> [String: Any] {
        let encodedMessages: [[String: Any]] = messages.map { msg in
            var m: [String: Any] = ["role": msg.role, "content": msg.content]
            if let tcId = msg.toolCallId { m["tool_call_id"] = tcId }
            if let tcs = msg.toolCalls {
                m["tool_calls"] = tcs.map { tc -> [String: Any] in
                    ["id": tc.id, "type": tc.type,
                     "function": ["name": tc.function.name, "arguments": tc.function.arguments]]
                }
            }
            return m
        }

        var payload: [String: Any] = [
            "model": model,
            "messages": encodedMessages,
            "stream": stream,
            "temperature": 0.7,
            "max_tokens": 1024,
        ]

        if !tools.isEmpty,
           let toolData = try? JSONEncoder().encode(tools),
           let toolArray = try? JSONSerialization.jsonObject(with: toolData) {
            payload["tools"] = toolArray
            payload["tool_choice"] = "auto"
        }

        return payload
    }
}
