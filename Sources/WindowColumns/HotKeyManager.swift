import AppKit
import Carbon.HIToolbox
import Foundation

final class HotKeyManager {
    var handler: ((Int) -> Void)?
    var createGroupHandler: (() -> Void)?
    var undoHandler: (() -> Void)?
    var openChooserHandler: (() -> Void)?
    var minimizeGroupHandler: (() -> Void)?
    private var hotKeys: [EventHotKeyRef] = []
    private var eventHandler: EventHandlerRef?
    private var globalModifierMonitor: Any?
    private var localModifierMonitor: Any?
    private var controlIsDown = false
    private var lastControlPress: TimeInterval = 0
    private var doubleTapModifier: DoubleTapModifier = .control
    private let signature: OSType = 0x57434F4C // "WCOL"

    /// Registers every configured shortcut, replacing whatever was registered
    /// before. Safe to call whenever the user changes a binding.
    @discardableResult
    func apply(_ preferences: LayoutPreferences) -> [String] {
        installEventHandlerIfNeeded()
        unregisterHotKeys()
        var rejected: [String] = []
        doubleTapModifier = preferences.doubleTapModifier

        let columnModifiers = ShortcutBinding(
            keyCode: 0, modifierFlags: preferences.columnModifierFlags
        ).carbonModifiers
        let keyCodes: [Int: UInt32] = [
            2: UInt32(kVK_ANSI_2), 3: UInt32(kVK_ANSI_3), 4: UInt32(kVK_ANSI_4),
            5: UInt32(kVK_ANSI_5), 6: UInt32(kVK_ANSI_6), 7: UInt32(kVK_ANSI_7),
            8: UInt32(kVK_ANSI_8), 9: UInt32(kVK_ANSI_9)
        ]
        if columnModifiers != 0 {
            var refusedColumns = false
            for count in 2...9 {
                if !register(keyCode: keyCodes[count]!, modifiers: columnModifiers, id: UInt32(count)) {
                    refusedColumns = true
                }
            }
            if refusedColumns {
                let symbols = ShortcutFormatter.modifierSymbols(
                    NSEvent.ModifierFlags(rawValue: preferences.columnModifierFlags)
                )
                rejected.append("Column shortcuts (\(symbols)2 … \(symbols)9)")
            }
        }
        // A combination already claimed by macOS or another app is refused, and
        // used to fail silently — indistinguishable from the feature being broken.
        if let undo = preferences.undoShortcut,
           !register(keyCode: UInt32(undo.keyCode), modifiers: undo.carbonModifiers, id: Identifier.undo) {
            rejected.append("Undo arrangement (\(undo.displayName))")
        }
        if let open = preferences.openChooserShortcut,
           !register(keyCode: UInt32(open.keyCode), modifiers: open.carbonModifiers, id: Identifier.openChooser) {
            rejected.append("Open the chooser (\(open.displayName))")
        }
        if let create = preferences.createGroupShortcut,
           !register(keyCode: UInt32(create.keyCode), modifiers: create.carbonModifiers, id: Identifier.createGroup) {
            rejected.append("New group (\(create.displayName))")
        }

        if let minimize = preferences.minimizeGroupShortcut,
           !register(keyCode: UInt32(minimize.keyCode), modifiers: minimize.carbonModifiers, id: Identifier.minimizeGroup) {
            rejected.append("Minimize group (\(minimize.displayName))")
        }

        startModifierMonitorsIfNeeded()
        return rejected
    }

    enum Identifier {
        static let undo: UInt32 = 1
        static let openChooser: UInt32 = 10
        static let createGroup: UInt32 = 11
        static let minimizeGroup: UInt32 = 12
    }

    @discardableResult
    private func register(keyCode: UInt32, modifiers: UInt32, id: UInt32) -> Bool {
        var reference: EventHotKeyRef?
        let identifier = EventHotKeyID(signature: signature, id: id)
        let status = RegisterEventHotKey(
            keyCode, modifiers, identifier, GetApplicationEventTarget(), 0, &reference
        )
        guard status == noErr, let reference else { return false }
        hotKeys.append(reference)
        return true
    }

    private func unregisterHotKeys() {
        hotKeys.forEach { UnregisterEventHotKey($0) }
        hotKeys.removeAll()
    }

    private func installEventHandlerIfNeeded() {
        guard eventHandler == nil else { return }
        var eventType = EventTypeSpec(
            eventClass: OSType(kEventClassKeyboard), eventKind: UInt32(kEventHotKeyPressed)
        )
        InstallEventHandler(
            GetApplicationEventTarget(),
            windowColumnsHotKeyCallback,
            1,
            &eventType,
            Unmanaged.passUnretained(self).toOpaque(),
            &eventHandler
        )
    }

    private func startModifierMonitorsIfNeeded() {
        guard globalModifierMonitor == nil else { return }
        globalModifierMonitor = NSEvent.addGlobalMonitorForEvents(matching: .flagsChanged) { [weak self] event in
            self?.handleModifierChange(event)
        }
        localModifierMonitor = NSEvent.addLocalMonitorForEvents(matching: .flagsChanged) { [weak self] event in
            self?.handleModifierChange(event)
            return event
        }
    }

    func stop() {
        unregisterHotKeys()
        if let eventHandler { RemoveEventHandler(eventHandler) }
        eventHandler = nil
        if let globalModifierMonitor { NSEvent.removeMonitor(globalModifierMonitor) }
        if let localModifierMonitor { NSEvent.removeMonitor(localModifierMonitor) }
        globalModifierMonitor = nil
        localModifierMonitor = nil
    }

    private func handleModifierChange(_ event: NSEvent) {
        guard let watched = doubleTapModifier.flag else { return }
        let flags = event.modifierFlags.intersection(.deviceIndependentFlagsMask)
        let isDown = flags.contains(watched)
        defer { controlIsDown = isDown }
        guard isDown, !controlIsDown else { return }

        guard flags.intersection(doubleTapModifier.competingFlags).isEmpty else {
            lastControlPress = 0
            return
        }

        let now = ProcessInfo.processInfo.systemUptime
        if now - lastControlPress <= 0.42 {
            lastControlPress = 0
            DispatchQueue.main.async { [weak self] in self?.createGroupHandler?() }
        } else {
            lastControlPress = now
        }
    }

    deinit { stop() }
}

private func windowColumnsHotKeyCallback(
    nextHandler: EventHandlerCallRef?,
    event: EventRef?,
    userData: UnsafeMutableRawPointer?
) -> OSStatus {
    guard let event, let userData else { return OSStatus(eventNotHandledErr) }
    var identifier = EventHotKeyID()
    let status = GetEventParameter(
        event,
        EventParamName(kEventParamDirectObject),
        EventParamType(typeEventHotKeyID),
        nil,
        MemoryLayout<EventHotKeyID>.size,
        nil,
        &identifier
    )
    guard status == noErr else { return OSStatus(eventNotHandledErr) }
    let manager = Unmanaged<HotKeyManager>.fromOpaque(userData).takeUnretainedValue()
    let id = identifier.id
    DispatchQueue.main.async {
        switch id {
        case HotKeyManager.Identifier.undo: manager.undoHandler?()
        case HotKeyManager.Identifier.openChooser: manager.openChooserHandler?()
        case HotKeyManager.Identifier.createGroup: manager.createGroupHandler?()
        case HotKeyManager.Identifier.minimizeGroup: manager.minimizeGroupHandler?()
        case 2...9: manager.handler?(Int(id))
        default: break
        }
    }
    return noErr
}
