# Copilot Instructions

## Build, test, and lint commands

| Task | Command | Notes |
| --- | --- | --- |
| Build macOS app | `swift build` | Run from repo root. Swift package target is `PersonalAssistant`. |
| Run macOS app | `.build/debug/PersonalAssistant` | Launches the menu-bar app after a successful build. |

There is currently no first-party test suite or lint configuration checked into this repository, so there is no project-level single-test command yet.

## High-level architecture

- The app runtime is the root Swift package (`Package.swift` + `src/`), built with SwiftUI + AppKit.
- The app talks directly to LM Studio (`http://127.0.0.1:1234`) using OpenAI-compatible endpoints:
  - `/v1/models` to resolve status and active model ID.
  - `/v1/chat/completions` for streaming chat completions.
- `AppDelegate` is the orchestration point: it sets accessory app mode, creates the menu bar item, registers the global hotkey (`Fn+Ctrl` via `CGEventTap`), starts MCP servers from user config, and periodically refreshes LM Studio status.
- UI is rendered in a custom borderless floating `NSPanel` (`AssistantPanel`) hosting `AssistantView`. The panel uses Liquid Glass styling directly on the root SwiftUI stack.
- `BackendClient` is the frontend integration core:
  - Fetches current model ID dynamically from LM Studio.
  - Runs a streaming-only chat loop.
  - Parses streamed `delta.tool_calls`, executes built-in tools and MCP tools, appends tool messages, then continues streaming until completion.
- MCP integration is split between:
  - `MCPManager`: starts/stops configured servers and routes tool calls by tool name.
  - `MCPServer`: JSON-RPC 2.0 client over stdio with initialize handshake, tool discovery (`tools/list`), and invocation (`tools/call`).
- Runtime config is user-scoped at `~/.config/pa/config.json` (seed from `config.json.example`); MCP servers are declared under `mcp_servers`.

## Key conventions in this codebase

- Frontend runtime services are `@MainActor` (`BackendClient`, `MCPManager`, `AppDelegate`, view model). When callbacks/timers capture actor-isolated state, use `Task { @MainActor in ... }`.
- Keep the frontend chat path streaming-only; do not replace it with a non-streaming request/response flow.
- Do not hardcode LM Studio model IDs in the frontend request path. Resolve current model from `/v1/models` before each chat request.
- For cross-actor data in Swift 6 strict concurrency, avoid sending `[String: Any]` across actor boundaries; serialize through JSON strings where needed (as done in `MCPServer` response handling).
- In `AssistantViewModel.send()`, only send `user` and `assistant` history back to the model; `tool` messages are internal to the tool-calling loop.
- Preserve the Markdown rendering theme override for assistant messages: `.markdownTheme(.gitHub.text { BackgroundColor(nil) })` to avoid an unwanted document background in bubbles.
