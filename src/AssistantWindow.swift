import AppKit
import SwiftUI

/// Borderless floating panel with Liquid Glass background.
/// Draggable via the toolbar area only (not the conversation or input).
final class AssistantPanel: NSPanel {
    private let panelCornerRadius: CGFloat = 16

    init() {
        super.init(
            contentRect: NSRect(x: 0, y: 0, width: 640, height: 460),
            styleMask: [
                .borderless,
                .nonactivatingPanel,
                .fullSizeContentView,
            ],
            backing: .buffered,
            defer: false
        )

        isFloatingPanel = true
        level = .floating
        collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        isMovableByWindowBackground = false  // Drag handled per-region in SwiftUI
        isOpaque = false
        backgroundColor = .clear
        hasShadow = false
        isReleasedWhenClosed = false
        hidesOnDeactivate = false

        contentView?.wantsLayer = true
        contentView?.layer?.cornerRadius = panelCornerRadius
        contentView?.layer?.masksToBounds = true
        contentView?.layer?.backgroundColor = NSColor.clear.cgColor

        let host = NSHostingView(rootView: AssistantView())
        host.frame = contentView!.bounds
        host.autoresizingMask = [.width, .height]
        host.wantsLayer = true
        host.layer?.cornerRadius = panelCornerRadius
        host.layer?.masksToBounds = true
        host.focusRingType = .none
        contentView?.focusRingType = .none
        contentView?.addSubview(host)
    }

    override func keyDown(with event: NSEvent) {
        if event.keyCode == 53 { orderOut(nil) } else { super.keyDown(with: event) }
    }

    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { false }  // Suppresses the macOS 26 focus-corner decoration
}

// ---------------------------------------------------------------------------
// Drag region — transparent NSView that calls window?.performDrag
// ---------------------------------------------------------------------------

struct WindowDragArea: NSViewRepresentable {
    func makeNSView(context: Context) -> DragView { DragView() }
    func updateNSView(_ nsView: DragView, context: Context) {}

    final class DragView: NSView {
        override func mouseDown(with event: NSEvent) {
            window?.performDrag(with: event)
        }
        // Don't block clicks from reaching SwiftUI buttons in the toolbar
        override func hitTest(_ point: NSPoint) -> NSView? {
            // Only intercept if the click landed directly on us, not a subview
            return super.hitTest(point) == self ? self : nil
        }
    }
}
