import AppKit
import Carbon
import CoreGraphics

/// Registers a global hotkey using CGEventTap.
/// Default: Fn (Globe) + Control.
final class HotKeyManager {
    private let handler: @Sendable () -> Void

    private let requiredFlags: CGEventFlags = [.maskSecondaryFn, .maskControl]
    private let blockedFlags: CGEventFlags = [.maskCommand, .maskShift, .maskAlternate]
    private var didTriggerForCurrentChord = false

    init(handler: @escaping @Sendable () -> Void) {
        self.handler = handler
        setupEventTap()
    }

    private func setupEventTap() {
        let mask = CGEventMask(1 << CGEventType.flagsChanged.rawValue)
        let selfPtr = Unmanaged.passRetained(self).toOpaque()

        let tap = CGEvent.tapCreate(
            tap: .cgSessionEventTap,
            place: .headInsertEventTap,
            options: .defaultTap,
            eventsOfInterest: mask,
            callback: { _, type, event, userInfo -> Unmanaged<CGEvent>? in
                guard type == .flagsChanged, let ptr = userInfo else {
                    return Unmanaged.passRetained(event)
                }
                let mgr = Unmanaged<HotKeyManager>.fromOpaque(ptr).takeUnretainedValue()

                let flags = event.flags.intersection([
                    .maskSecondaryFn, .maskControl, .maskCommand, .maskShift, .maskAlternate
                ])
                let hasRequired = flags.contains(mgr.requiredFlags)
                let hasBlocked = !flags.intersection(mgr.blockedFlags).isEmpty
                let chordActive = hasRequired && !hasBlocked

                if chordActive && !mgr.didTriggerForCurrentChord {
                    mgr.didTriggerForCurrentChord = true
                    mgr.handler()
                } else if !chordActive {
                    mgr.didTriggerForCurrentChord = false
                }
                return Unmanaged.passRetained(event)
            },
            userInfo: selfPtr
        )

        guard let tap else {
            // Prompt for Accessibility permission — string literal avoids Swift 6 global-var warning
            AXIsProcessTrustedWithOptions(["AXTrustedCheckOptionPrompt": true] as CFDictionary)
            return
        }

        let source = CFMachPortCreateRunLoopSource(kCFAllocatorDefault, tap, 0)
        CFRunLoopAddSource(CFRunLoopGetMain(), source, .commonModes)
        CGEvent.tapEnable(tap: tap, enable: true)
    }
}
