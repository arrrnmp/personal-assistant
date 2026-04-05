import Foundation

// ---------------------------------------------------------------------------
// Loads MCP server configs from ~/.config/pa/config.json and manages them
// ---------------------------------------------------------------------------

struct MCPServerConfig: Decodable {
    let label: String
    let command: String
    let args: [String]
    let env: [String: String]?
}

@MainActor
final class MCPManager {
    static let shared = MCPManager()

    private(set) var servers: [MCPServer] = []

    /// All tool definitions from every running MCP server.
    var toolDefinitions: [ToolDefinition] {
        servers.flatMap { $0.tools.map(\.asToolDefinition) }
    }

    func start(configs: [MCPServerConfig]) async {
        for cfg in configs {
            let server = MCPServer(
                label: cfg.label,
                command: cfg.command,
                args: cfg.args,
                env: cfg.env ?? [:]
            )
            do {
                try await server.start()
                servers.append(server)
                print("MCP server '\(cfg.label)' started with \(server.tools.count) tools.")
            } catch {
                print("MCP server '\(cfg.label)' failed to start: \(error.localizedDescription)")
            }
        }
    }

    func stopAll() {
        servers.forEach { $0.stop() }
        servers.removeAll()
    }

    /// Returns the server that owns a tool name, if any.
    func server(for toolName: String) -> MCPServer? {
        servers.first { $0.tools.contains { $0.name == toolName } }
    }

    func canHandle(_ toolName: String) -> Bool {
        server(for: toolName) != nil
    }

    func callTool(name: String, arguments: [String: Any]) async throws -> String {
        guard let server = server(for: name) else {
            throw NSError(domain: "MCP", code: -1,
                          userInfo: [NSLocalizedDescriptionKey: "No MCP server owns tool '\(name)'"])
        }
        return try await server.callTool(name: name, arguments: arguments)
    }
}
