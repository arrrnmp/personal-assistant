import AppKit
import SwiftUI

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    var statusItem: NSStatusItem?
    var assistantWindow: AssistantPanel?
    var hotKeyManager: HotKeyManager?

    private var statusMenuItem: NSMenuItem?

    // MARK: - Launch

    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.setActivationPolicy(.accessory)

        setupMenuBar()

        hotKeyManager = HotKeyManager { [weak self] in
            Task { @MainActor [weak self] in self?.toggleAssistant() }
        }

        Task { await startMCPServers() }

        Timer.scheduledTimer(withTimeInterval: 5, repeats: true) { [weak self] _ in
            Task { @MainActor [weak self] in self?.refreshStatus() }
        }
        refreshStatus()
    }

    // MARK: - Menu bar

    private func setupMenuBar() {
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)

        if let button = statusItem?.button {
            button.image = NSImage(systemSymbolName: "brain", accessibilityDescription: "Personal Assistant")
            button.toolTip = "Personal Assistant (Fn+Ctrl)"
        }

        let menu = NSMenu()

        let showItem = NSMenuItem(title: "Show Assistant", action: #selector(showAssistant), keyEquivalent: "")
        showItem.target = self
        menu.addItem(showItem)

        menu.addItem(.separator())

        let si = NSMenuItem(title: "LM Studio: checking…", action: nil, keyEquivalent: "")
        si.isEnabled = false
        statusMenuItem = si
        menu.addItem(si)

        menu.addItem(.separator())

        let quitItem = NSMenuItem(
            title: "Quit Personal Assistant",
            action: #selector(NSApplication.terminate(_:)),
            keyEquivalent: "q"
        )
        menu.addItem(quitItem)

        self.statusItem?.menu = menu
    }

    @objc private func showAssistant() { toggleAssistant() }

    private func toggleAssistant() {
        if let window = assistantWindow, window.isVisible {
            window.orderOut(nil)
        } else {
            showHUD()
        }
    }

    private func showHUD() {
        if assistantWindow == nil {
            assistantWindow = AssistantPanel()
        }
        assistantWindow?.center()
        assistantWindow?.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
    }

    // MARK: - MCP

    private func startMCPServers() async {
        let configURL = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent(".config/pa/config.json")
        guard let data = try? Data(contentsOf: configURL),
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let rawServers = json["mcp_servers"] as? [[String: Any]],
              let configs = try? JSONDecoder().decode(
                [MCPServerConfig].self,
                from: JSONSerialization.data(withJSONObject: rawServers)
              )
        else { return }

        await MCPManager.shared.start(configs: configs)
    }

    // MARK: - Status

    private func refreshStatus() {
        Task {
            let label: String
            if let status = try? await BackendClient.shared.fetchStatus() {
                switch status.state {
                case .modelLoaded(let id):
                    let short = id.split(separator: "/").last.map(String.init) ?? id
                    label = "LM Studio: \(short)"
                case .idle:
                    label = "LM Studio: running (no model loaded)"
                case .unreachable:
                    label = "LM Studio: not running"
                }
            } else {
                label = "LM Studio: not running"
            }
            statusMenuItem?.title = label
        }
    }
}
