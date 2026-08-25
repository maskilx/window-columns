import AppKit
import Carbon.HIToolbox
import SwiftUI

/// A global shortcut: a virtual key plus the modifiers held with it.
struct ShortcutBinding: Codable, Equatable, Hashable {
    var keyCode: UInt16
    /// `NSEvent.ModifierFlags` raw value, device independent.
    var modifierFlags: UInt

    var flags: NSEvent.ModifierFlags { NSEvent.ModifierFlags(rawValue: modifierFlags) }

    var carbonModifiers: UInt32 {
        var result: UInt32 = 0
        if flags.contains(.command) { result |= UInt32(cmdKey) }
        if flags.contains(.option) { result |= UInt32(optionKey) }
        if flags.contains(.control) { result |= UInt32(controlKey) }
        if flags.contains(.shift) { result |= UInt32(shiftKey) }
        return result
    }

    var displayName: String {
        ShortcutFormatter.modifierSymbols(flags) + ShortcutFormatter.keyName(keyCode)
    }

    /// Not plain ⌘M: registering that globally would break Minimize in every
    /// application on the Mac.
    static let minimizeGroupDefault = ShortcutBinding(
        keyCode: UInt16(kVK_ANSI_M),
        modifierFlags: NSEvent.ModifierFlags([.control, .option, .command]).rawValue
    )

    static let undoDefault = ShortcutBinding(
        keyCode: UInt16(kVK_ANSI_Z),
        modifierFlags: NSEvent.ModifierFlags([.control, .option, .command]).rawValue
    )
}

/// Tapping a modifier twice, quickly, with nothing else held.
enum DoubleTapModifier: String, Codable, CaseIterable, Identifiable {
    case off, control, option, command, shift

    var id: String { rawValue }

    var label: String {
        switch self {
        case .off: return "Off"
        case .control: return "⌃ Control"
        case .option: return "⌥ Option"
        case .command: return "⌘ Command"
        case .shift: return "⇧ Shift"
        }
    }

    var flag: NSEvent.ModifierFlags? {
        switch self {
        case .off: return nil
        case .control: return .control
        case .option: return .option
        case .command: return .command
        case .shift: return .shift
        }
    }

    /// The modifiers that must *not* be held, so ⌃⌘ never counts as a ⌃ tap.
    var competingFlags: NSEvent.ModifierFlags {
        let all: NSEvent.ModifierFlags = [.command, .option, .control, .shift]
        guard let flag else { return all }
        return all.subtracting(flag)
    }
}

enum ShortcutFormatter {
    static func modifierSymbols(_ flags: NSEvent.ModifierFlags) -> String {
        var symbols = ""
        if flags.contains(.control) { symbols += "⌃" }
        if flags.contains(.option) { symbols += "⌥" }
        if flags.contains(.shift) { symbols += "⇧" }
        if flags.contains(.command) { symbols += "⌘" }
        return symbols
    }

    /// Names for the keys a shortcut is plausibly bound to. Anything else falls
    /// back to its virtual key code rather than guessing at a layout-dependent
    /// character.
    static func keyName(_ keyCode: UInt16) -> String {
        if let name = named[Int(keyCode)] { return name }
        return "Key \(keyCode)"
    }

    private static let named: [Int: String] = [
        kVK_ANSI_A: "A", kVK_ANSI_B: "B", kVK_ANSI_C: "C", kVK_ANSI_D: "D",
        kVK_ANSI_E: "E", kVK_ANSI_F: "F", kVK_ANSI_G: "G", kVK_ANSI_H: "H",
        kVK_ANSI_I: "I", kVK_ANSI_J: "J", kVK_ANSI_K: "K", kVK_ANSI_L: "L",
        kVK_ANSI_M: "M", kVK_ANSI_N: "N", kVK_ANSI_O: "O", kVK_ANSI_P: "P",
        kVK_ANSI_Q: "Q", kVK_ANSI_R: "R", kVK_ANSI_S: "S", kVK_ANSI_T: "T",
        kVK_ANSI_U: "U", kVK_ANSI_V: "V", kVK_ANSI_W: "W", kVK_ANSI_X: "X",
        kVK_ANSI_Y: "Y", kVK_ANSI_Z: "Z",
        kVK_ANSI_0: "0", kVK_ANSI_1: "1", kVK_ANSI_2: "2", kVK_ANSI_3: "3",
        kVK_ANSI_4: "4", kVK_ANSI_5: "5", kVK_ANSI_6: "6", kVK_ANSI_7: "7",
        kVK_ANSI_8: "8", kVK_ANSI_9: "9",
        kVK_Space: "Space", kVK_Return: "Return", kVK_Tab: "Tab",
        kVK_ANSI_Grave: "`", kVK_ANSI_Minus: "-", kVK_ANSI_Equal: "=",
        kVK_ANSI_LeftBracket: "[", kVK_ANSI_RightBracket: "]",
        kVK_ANSI_Backslash: "\\", kVK_ANSI_Semicolon: ";", kVK_ANSI_Quote: "'",
        kVK_ANSI_Comma: ",", kVK_ANSI_Period: ".", kVK_ANSI_Slash: "/",
        kVK_F1: "F1", kVK_F2: "F2", kVK_F3: "F3", kVK_F4: "F4", kVK_F5: "F5",
        kVK_F6: "F6", kVK_F7: "F7", kVK_F8: "F8", kVK_F9: "F9", kVK_F10: "F10",
        kVK_F11: "F11", kVK_F12: "F12",
        kVK_LeftArrow: "←", kVK_RightArrow: "→", kVK_UpArrow: "↑", kVK_DownArrow: "↓"
    ]
}

/// Captures one keystroke and reports it as a binding.
///
/// Recording goes through a local event monitor rather than `keyDown`. Relying
/// on the responder chain does not work here: anything containing Command is
/// matched against the main menu as a key equivalent before `keyDown` is ever
/// dispatched, and SwiftUI's `Form` competes for focus besides — so most
/// shortcuts simply never arrived.
final class ShortcutRecorderNSView: NSView {
    var onCapture: ((ShortcutBinding?) -> Void)?
    var binding: ShortcutBinding?
    var placeholder = "Click to record"

    private var monitor: Any?
    private var isRecording = false { didSet { needsDisplay = true } }

    override var acceptsFirstResponder: Bool { true }
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

    override func mouseDown(with event: NSEvent) {
        isRecording ? stopRecording() : startRecording()
    }

    private func startRecording() {
        guard monitor == nil else { return }
        isRecording = true
        window?.makeFirstResponder(self)
        monitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
            guard let self, self.isRecording else { return event }
            self.handle(event)
            return nil
        }
    }

    private func stopRecording() {
        if let monitor { NSEvent.removeMonitor(monitor) }
        monitor = nil
        isRecording = false
    }

    private func handle(_ event: NSEvent) {
        if event.keyCode == UInt16(kVK_Escape) {
            stopRecording()
            return
        }
        if event.keyCode == UInt16(kVK_Delete) || event.keyCode == UInt16(kVK_ForwardDelete) {
            stopRecording()
            binding = nil
            onCapture?(nil)
            return
        }
        let flags = event.modifierFlags
            .intersection(.deviceIndependentFlagsMask)
            .intersection([.command, .option, .control, .shift])
        // A global shortcut without a modifier would swallow that key everywhere.
        guard !flags.isEmpty else {
            NSSound.beep()
            return
        }
        let captured = ShortcutBinding(keyCode: event.keyCode, modifierFlags: flags.rawValue)
        stopRecording()
        binding = captured
        onCapture?(captured)
    }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        if window == nil { stopRecording() }
    }

    deinit {
        if let monitor { NSEvent.removeMonitor(monitor) }
    }

    override func draw(_ dirtyRect: NSRect) {
        let rounded = NSBezierPath(roundedRect: bounds.insetBy(dx: 1, dy: 1), xRadius: 7, yRadius: 7)
        (isRecording ? NSColor.controlAccentColor.withAlphaComponent(0.16)
                     : NSColor.controlBackgroundColor).setFill()
        rounded.fill()
        (isRecording ? NSColor.controlAccentColor : NSColor.separatorColor).setStroke()
        rounded.lineWidth = isRecording ? 2 : 1
        rounded.stroke()

        let text = isRecording ? "Type a shortcut…" : (binding?.displayName ?? placeholder)
        let attributes: [NSAttributedString.Key: Any] = [
            .font: NSFont.systemFont(ofSize: 12, weight: binding == nil ? .regular : .semibold),
            .foregroundColor: binding == nil && !isRecording ? NSColor.secondaryLabelColor : NSColor.labelColor
        ]
        let size = (text as NSString).size(withAttributes: attributes)
        (text as NSString).draw(
            at: NSPoint(x: (bounds.width - size.width) / 2, y: (bounds.height - size.height) / 2),
            withAttributes: attributes
        )
    }
}

struct ShortcutRecorder: NSViewRepresentable {
    let placeholder: String
    @Binding var binding: ShortcutBinding?

    func makeNSView(context: Context) -> ShortcutRecorderNSView {
        let view = ShortcutRecorderNSView()
        view.placeholder = placeholder
        view.binding = binding
        view.onCapture = { binding = $0 }
        return view
    }

    func updateNSView(_ nsView: ShortcutRecorderNSView, context: Context) {
        nsView.placeholder = placeholder
        if nsView.binding != binding {
            nsView.binding = binding
            nsView.needsDisplay = true
        }
        nsView.onCapture = { binding = $0 }
    }
}
