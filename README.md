# Personal Assistant (macOS)

A local-first macOS menu bar assistant built with SwiftUI + AppKit.

It talks directly to **LM Studio** over its OpenAI-compatible API, supports streaming responses, and can call built-in and MCP tools.

## Requirements

- macOS 26+
- Swift 6.2 toolchain
- LM Studio running with local server enabled at `http://127.0.0.1:1234`

## Quick start

```bash
# from repo root
swift build
.build/debug/PersonalAssistant
```

## Configuration

At startup, the app reads config from:

`~/.config/pa/config.json`

Seed it from the repository template:

```bash
mkdir -p ~/.config/pa
cp config.json.example ~/.config/pa/config.json
```

You can configure:
- LM Studio port
- generation defaults (`max_tokens`, `temperature`, `system_prompt`)
- MCP servers under `mcp_servers`

## Usage

- Open from the menu bar icon.
- Global shortcut: **Fn (Globe) + Control**
- Press `Esc` to hide the assistant panel.

## Architecture overview

- `src/AppDelegate.swift`  
  App lifecycle, menu bar item, global hotkey registration, LM Studio status polling, MCP startup.
- `src/AssistantWindow.swift` + `src/AssistantView.swift`  
  Floating panel + SwiftUI chat UI.
- `src/BackendClient.swift`  
  Streaming chat loop, model discovery via `/v1/models`, tool-call handling via `/v1/chat/completions`.
- `src/BuiltinTools.swift`  
  Built-in tools (`get_current_datetime`, `get_weather`).
- `src/MCPManager.swift` + `src/MCPServer.swift`  
  MCP server process management + JSON-RPC stdio client.

## Notes

- This repository is Swift-only (no Python backend layer).
- There is currently no first-party test/lint suite checked in.
