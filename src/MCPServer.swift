import Foundation

// ---------------------------------------------------------------------------
// Minimal MCP client over stdio (JSON-RPC 2.0)
// ---------------------------------------------------------------------------

struct MCPToolDefinition {
    let name: String
    let description: String
    let inputSchema: [String: Any]

    var asToolDefinition: ToolDefinition {
        var properties: [String: ToolDefinition.Parameter] = [:]
        var required: [String] = []

        if let props = inputSchema["properties"] as? [String: [String: Any]] {
            for (key, schema) in props {
                let type = schema["type"] as? String ?? "string"
                let desc = schema["description"] as? String ?? ""
                let enumVals = schema["enum"] as? [String]
                properties[key] = .init(type: type, description: desc, enum: enumVals)
            }
        }
        if let req = inputSchema["required"] as? [String] { required = req }

        return ToolDefinition(
            function: .init(
                name: name,
                description: description,
                parameters: .init(properties: properties, required: required)
            )
        )
    }
}

@MainActor
final class MCPServer {
    let label: String
    private(set) var tools: [MCPToolDefinition] = []

    private let process = Process()
    private let stdinPipe = Pipe()
    private let stdoutPipe = Pipe()
    private var buffer = Data()
    private var requestID = 0
    private var pending: [Int: CheckedContinuation<String, Error>] = [:]

    init(label: String, command: String, args: [String], env: [String: String] = [:]) {
        self.label = label
        process.executableURL = URL(fileURLWithPath: command)
        process.arguments = args
        var environment = ProcessInfo.processInfo.environment
        env.forEach { environment[$0] = $1 }
        process.environment = environment
        process.standardInput = stdinPipe
        process.standardOutput = stdoutPipe
        process.standardError = FileHandle.nullDevice
    }

    // MARK: - Lifecycle

    func start() async throws {
        // Read stdout via readabilityHandler — dispatches back to @MainActor for buffer processing
        stdoutPipe.fileHandleForReading.readabilityHandler = { [weak self] handle in
            let data = handle.availableData
            guard !data.isEmpty else { return }
            Task { @MainActor [weak self] in
                self?.buffer.append(data)
                self?.processBuffer()
            }
        }

        try process.run()

        // MCP initialize handshake
        _ = try await send(method: "initialize", params: [
            "protocolVersion": "2024-11-05",
            "capabilities": [:] as [String: String],
            "clientInfo": ["name": "PersonalAssistant", "version": "1.0"]
        ])
        try await sendNotification(method: "notifications/initialized")

        // Discover available tools
        let toolsJSON = try await send(method: "tools/list", params: [:] as [String: String])
        if let data = toolsJSON.data(using: .utf8),
           let result = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
           let toolsArray = result["tools"] as? [[String: Any]] {
            tools = toolsArray.compactMap { t in
                guard let name = t["name"] as? String,
                      let desc = t["description"] as? String else { return nil }
                let schema = t["inputSchema"] as? [String: Any] ?? [:]
                return MCPToolDefinition(name: name, description: desc, inputSchema: schema)
            }
        }
    }

    func stop() {
        stdoutPipe.fileHandleForReading.readabilityHandler = nil
        process.terminate()
    }

    // MARK: - Tool call

    func callTool(name: String, arguments: [String: Any]) async throws -> String {
        let resultJSON = try await send(method: "tools/call", params: [
            "name": name,
            "arguments": arguments
        ] as [String: Any])
        guard let data = resultJSON.data(using: .utf8),
              let r = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let content = r["content"] as? [[String: Any]] else {
            return resultJSON
        }
        return content.compactMap { $0["text"] as? String }.joined(separator: "\n")
    }

    // MARK: - JSON-RPC primitives

    /// Sends a JSON-RPC request and returns the result as a JSON string.
    private func send(method: String, params: Any) async throws -> String {
        requestID += 1
        let id = requestID
        let message: [String: Any] = [
            "jsonrpc": "2.0",
            "id": id,
            "method": method,
            "params": params
        ]
        try write(message)
        return try await withCheckedThrowingContinuation { continuation in
            pending[id] = continuation
        }
    }

    private func sendNotification(method: String) throws {
        try write(["jsonrpc": "2.0", "method": method])
    }

    private func write(_ object: [String: Any]) throws {
        var data = try JSONSerialization.data(withJSONObject: object)
        data.append(0x0a) // newline-delimited JSON
        stdinPipe.fileHandleForWriting.write(data)
    }

    // MARK: - Buffer processing (always called on @MainActor)

    private func processBuffer() {
        while let newlineIdx = buffer.firstIndex(of: 0x0a) {
            let lineData = buffer[buffer.startIndex..<newlineIdx]
            buffer.removeSubrange(buffer.startIndex...newlineIdx)
            guard !lineData.isEmpty,
                  let obj = try? JSONSerialization.jsonObject(with: lineData) as? [String: Any]
            else { continue }
            dispatchResponse(obj)
        }
    }

    private func dispatchResponse(_ obj: [String: Any]) {
        guard let id = obj["id"] as? Int,
              let cont = pending.removeValue(forKey: id) else { return }
        if let error = obj["error"] as? [String: Any] {
            let msg = error["message"] as? String ?? "MCP error"
            cont.resume(throwing: NSError(domain: "MCP", code: -1,
                                          userInfo: [NSLocalizedDescriptionKey: msg]))
        } else {
            // Serialise result back to JSON string (String is Sendable)
            let result = obj["result"] ?? [:]
            let json = (try? JSONSerialization.data(withJSONObject: result))
                .flatMap { String(data: $0, encoding: .utf8) } ?? "{}"
            cont.resume(returning: json)
        }
    }
}
