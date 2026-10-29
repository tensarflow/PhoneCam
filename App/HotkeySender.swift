import ApplicationServices
import CoreGraphics

/// Presses Right Option (FluidVoice's dictation shortcut) for the PhoneCam Mic app's Talk button.
/// Posting key events needs the Accessibility permission.
enum HotkeySender {
    static var isAllowed: Bool { AXIsProcessTrusted() }

    /// Shows macOS's "allow PhoneCam to control this computer" prompt.
    static func requestPermission() {
        let options = [kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String: true] as CFDictionary
        _ = AXIsProcessTrustedWithOptions(options)
    }

    /// A modifier key on its own is a flagsChanged event, not keyDown/keyUp.
    static func rightOption(down: Bool) {
        let source = CGEventSource(stateID: .hidSystemState)
        guard let event = CGEvent(keyboardEventSource: source, virtualKey: 61, keyDown: down) else { return }
        event.type = .flagsChanged
        // Down: Alternate (0x80000) | right-option device bit (0x40) | non-coalesced (0x100). Up: 0x100.
        event.flags = CGEventFlags(rawValue: down ? 0x80140 : 0x100)
        event.post(tap: .cghidEventTap)
    }
}
