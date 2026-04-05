# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## Build

```bash
# Build Swift app (from repo root)
swift build

# Run the app
.build/debug/PersonalAssistant
```

Always build after Swift changes and fix all errors and warnings before finishing.

## Architecture

Primary runtime layer:

**Swift app** (`src/`) — macOS 26 menu bar app built with SwiftUI + AppKit.
- `AppDelegate` owns the app lifecycle: spawns the `AssistantPanel`, registers the global hotkey (`Fn+Ctrl` via `CGEventTap`), and starts MCP servers from config on launch.
- `AssistantPanel` is a borderless `NSPanel` (`.borderless`, `isOpaque = false`, `canBecomeMain = false`) with `.glassEffect(in: RoundedRectangle)` applied directly to the root `VStack` in `AssistantView`.
- `BackendClient` (singleton, `@MainActor`) handles all LM Studio communication. The `chat()` method is a **streaming-only** tool-calling loop: it parses `delta.tool_calls` chunks from the SSE stream, executes tools, then loops. Never use a non-streaming round-trip for the chat path.
- `BuiltinToolRegistry` provides `get_current_datetime` and `get_weather` (Open-Meteo, no API key). `MCPManager` manages zero or more MCP server subprocesses (JSON-RPC 2.0 over stdio). Both are `@MainActor`.
- Entire codebase targets Swift 6 strict concurrency. `[String: Any]` crossing actor boundaries must go through JSON strings (see `MCPServer`). Use `Task { @MainActor in }` for closures that capture `self` from timers or hotkey callbacks.

**Inference** — LM Studio local server at `http://127.0.0.1:1234`. The app hits `/v1/models` for status and `/v1/chat/completions` for streaming chat. No model ID is hardcoded; it is resolved dynamically from `/v1/models` before each request.

**Config** — `~/.config/pa/config.json` (seed from `config.json.example`). MCP servers are declared there under `"mcp_servers"` and spawned at launch.

## Key dependencies

- `swift-markdown-ui` (gonzalezreal) — Markdown rendering in assistant bubbles. Use `.markdownTheme(.gitHub.text { BackgroundColor(nil) })` to strip the theme's document background.
