import AppKit
@preconcurrency import ApplicationServices
import Foundation
import SwiftUI

/// Brings other applications forward from a background accessory process.
///
/// Since macOS 14 an application that is not itself frontmost cannot simply call
/// `NSRunningApplication.activate(options:)`; cooperative activation silently
/// denies the request, which is why Command-Tabbing to a group companion used to
/// leave the real windows behind. Two mechanisms fix that:
///
/// 1. The companion that *is* frontmost yields its activation right to the
///    controller, so `activate(from:)` is honoured on macOS 14 and later.
/// 2. `kAXFrontmostAttribute` on the target's application element, which is
///    granted to any Accessibility-trusted process and is unaffected by
///    cooperative activation.
///
/// Both are attempted; the Accessibility route is the reliable one and the
/// AppKit route keeps the activation bookkeeping (Command-Tab order, menu bar)
/// correct.
enum WindowActivator {
    /// Makes the application owning `pid` frontmost.
    ///
    /// - Parameter donorPID: the process that currently holds activation and has
    ///   yielded it to us, when one is known.
    @discardableResult
    static func makeFrontmost(pid: pid_t, donorPID: pid_t?) -> Bool {
        let target = NSRunningApplication(processIdentifier: pid)
        var activated = false

        if #available(macOS 14.0, *),
           let target,
           let donorPID,
           let donor = NSRunningApplication(processIdentifier: donorPID),
           !donor.isTerminated {
            activated = target.activate(from: donor)
        }
        if !activated, let target {
            activated = target.activate()
        }

        // The Accessibility route works even when cooperative activation refuses
        // the AppKit call, so always issue it as well.
        let applicationElement = AXUIElementCreateApplication(pid)
        let result = AXUIElementSetAttributeValue(
            applicationElement,
            kAXFrontmostAttribute as CFString,
            kCFBooleanTrue
        )
        return activated || result == .success
    }

    /// Raises a window without changing which application is frontmost.
    static func raise(_ window: AXUIElement) {
        AXUIElementPerformAction(window, kAXRaiseAction as CFString)
    }

    /// Makes `window` the app's main, focused window.
    static func focus(_ window: AXUIElement) {
        AXUIElementSetAttributeValue(window, kAXMainAttribute as CFString, kCFBooleanTrue)
        AXUIElementSetAttributeValue(window, kAXFocusedAttribute as CFString, kCFBooleanTrue)
    }

    /// Brings this process forward. Used for the chooser panel, which is opened
    /// from a global hot key while another application owns activation.
    static func activateSelf() {
        NSApp.activate(ignoringOtherApps: true)
        if !NSApp.isActive {
            let selfElement = AXUIElementCreateApplication(ProcessInfo.processInfo.processIdentifier)
            AXUIElementSetAttributeValue(selfElement, kAXFrontmostAttribute as CFString, kCFBooleanTrue)
        }
    }
}

/// Opens the app's Settings window.
///
/// SwiftUI's `Settings` scene does not materialise for an accessory app: the
/// `showSettingsWindow:` action reports that it was handled and no window is
/// ever created, which left every settings entry point silently doing nothing.
/// Owning the window directly removes that dependency.
@MainActor
enum SettingsWindow {
    private static var controller: NSWindowController?

    static func open(model: AppModel) {
        if controller == nil {
            let window = NSWindow(
                contentRect: NSRect(x: 0, y: 0, width: 520, height: 460),
                styleMask: [.titled, .closable, .miniaturizable],
                backing: .buffered,
                defer: false
            )
            window.title = "Window Columns Settings"
            window.isReleasedWhenClosed = false
            window.contentView = NSHostingView(rootView: SettingsWindowContent(model: model))
            window.setContentSize(NSSize(width: 520, height: 460))
            window.center()
            controller = NSWindowController(window: window)
        }
        WindowActivator.activateSelf()
        controller?.window?.makeKeyAndOrderFront(nil)
        controller?.window?.orderFrontRegardless()
    }
}

/// Distributed notification names shared with the group companion helpers.
/// The helper target is standalone, so it repeats these literals rather than
/// importing them.
enum GroupHostChannel {
    static let controllerBundleID = "com.adimaskil.WindowColumns"
    static let activationRequest = Notification.Name("com.adimaskil.WindowColumns.activateGroup")
    static let activationSucceeded = Notification.Name("com.adimaskil.WindowColumns.activateGroup.succeeded")
    static let activationFailed = Notification.Name("com.adimaskil.WindowColumns.activateGroup.failed")
    static let groupRenamed = Notification.Name("com.adimaskil.WindowColumns.groupRenamed")
    /// Posted by a companion that is shutting down on purpose. Its absence is
    /// what distinguishes a crash from the user quitting the companion.
    static let companionQuitting = Notification.Name("com.adimaskil.WindowColumns.companionQuitting")
    /// Asked for from a companion's Dock menu.
    static let minimizeRequest = Notification.Name("com.adimaskil.WindowColumns.minimizeGroup")
    /// Broadcast when a group is minimized so its companion can suppress cascade activation.
    static let groupMinimized = Notification.Name("com.adimaskil.WindowColumns.groupMinimized")

    /// The helper encodes `<group uuid>|<helper pid>` so the controller can use
    /// the helper as the activation donor. Older helpers post the bare UUID.
    static func decodeRequest(_ object: String) -> (groupID: UUID, helperPID: pid_t?)? {
        let parts = object.split(separator: "|", maxSplits: 1, omittingEmptySubsequences: false)
        guard let id = UUID(uuidString: String(parts[0])) else { return nil }
        let pid = parts.count > 1 ? pid_t(String(parts[1])) : nil
        return (id, pid)
    }
}
