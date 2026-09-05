import AppKit
import Foundation
import WindowColumnsCore

private let controllerBundleID = "com.adimaskil.WindowColumns"
private let activationRequest = Notification.Name("com.adimaskil.WindowColumns.activateGroup")
private let activationSucceeded = Notification.Name("com.adimaskil.WindowColumns.activateGroup.succeeded")
private let activationFailed = Notification.Name("com.adimaskil.WindowColumns.activateGroup.failed")
private let groupRenamed = Notification.Name("com.adimaskil.WindowColumns.groupRenamed")
private let companionQuitting = Notification.Name("com.adimaskil.WindowColumns.companionQuitting")
private let minimizeRequest = Notification.Name("com.adimaskil.WindowColumns.minimizeGroup")
private let groupMinimized = Notification.Name("com.adimaskil.WindowColumns.groupMinimized")

/// A window group's Dock and Command-Tab stand-in.
///
/// The helper owns no windows. Its only job is to notice that the user selected
/// it — through Command-Tab, the Dock, or Spotlight — and hand activation to the
/// controller so the real group comes forward. If the controller cannot restore
/// the group the helper steps aside instead of leaving the user in an empty
/// application with an empty menu bar.
@MainActor
final class GroupHostDelegate: NSObject, NSApplicationDelegate {
    private let groupID: String
    private var groupName: String
    private var activationState = CompanionActivationState()
    private var handoffTimeout: DispatchWorkItem?
    /// Set when this helper is shutting down because the controller went away,
    /// which is not the user dismantling the group.
    private var isFollowingControllerOut = false
    private var observers: [NSObjectProtocol] = []
    private var workspaceObserver: NSObjectProtocol?
    private var controllerExitSource: DispatchSourceProcess?

    override init() {
        let arguments = ProcessInfo.processInfo.arguments
        func value(after flag: String) -> String? {
            guard let index = arguments.firstIndex(of: flag),
                  arguments.indices.contains(index + 1) else { return nil }
            return arguments[index + 1]
        }
        groupID = value(after: "--group-id") ?? ""
        groupName = value(after: "--group-name") ?? "Window Group"
        // Companions launch in the background. Every later activation belongs
        // to the user; a startup deadline used to swallow their first Command-Tab.
        super.init()
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.setActivationPolicy(.regular)
        NSApp.dockTile.badgeLabel = groupName
        watchController()

        // Secondary net. NSWorkspace does post this for an ordinary quit, but it
        // does not arrive when the controller is killed outright, which is why
        // the kernel-level watch above exists.
        workspaceObserver = NSWorkspace.shared.notificationCenter.addObserver(
            forName: NSWorkspace.didTerminateApplicationNotification,
            object: nil,
            queue: .main
        ) { [weak self] notification in
            guard let application = notification.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication,
                  application.bundleIdentifier == controllerBundleID else { return }
            MainActor.assumeIsolated {
                self?.isFollowingControllerOut = true
                NSApp.terminate(nil)
            }
        }
        observers.append(DistributedNotificationCenter.default().addObserver(
            forName: groupRenamed,
            object: nil,
            queue: .main
        ) { [weak self] notification in
            guard let value = notification.object as? String else { return }
            let parts = value.split(separator: "|", maxSplits: 1, omittingEmptySubsequences: false)
            guard parts.count == 2, String(parts[0]) == self?.groupID else { return }
            let renamed = String(parts[1])
            Task { @MainActor in
                self?.groupName = renamed
                NSApp.dockTile.badgeLabel = renamed
            }
        })
        for (name, handled) in [(activationSucceeded, true), (activationFailed, false)] {
            observers.append(DistributedNotificationCenter.default().addObserver(
                forName: name,
                object: nil,
                queue: .main
            ) { [weak self] notification in
                guard notification.object as? String == self?.groupID else { return }
                Task { @MainActor in
                    self?.handoffCompleted(restored: handled)
                }
            })
        }
        observers.append(DistributedNotificationCenter.default().addObserver(
            forName: groupMinimized,
            object: nil,
            queue: .main
        ) { [weak self] notification in
            guard let self, notification.object as? String == self.groupID else { return }
            Task { @MainActor in
                // Only suppress the immediate focus cascade caused by minimizing.
                // Keeping a minimized flag here permanently swallowed Command-Tab.
                self.activationState.didMinimize(at: Date())
            }
        })
    }

    /// Quitting the companion dismantles its group — that is the point of the
    /// Dock and Command-Tab entry. Announcing it here is what lets the
    /// controller tell a deliberate quit from a crash: this never runs when the
    /// process is killed, so a crash rebuilds the companion instead of
    /// destroying the user's group.
    func applicationWillTerminate(_ notification: Notification) {
        // Following the controller out is not a dismantle, so stay silent —
        // otherwise a controller that restarts quickly could hear this and
        // delete the group.
        guard !groupID.isEmpty, !isFollowingControllerOut else { return }
        DistributedNotificationCenter.default().postNotificationName(
            companionQuitting,
            object: groupID,
            userInfo: nil,
            deliverImmediately: true
        )
    }

    func applicationDidBecomeActive(_ notification: Notification) {
        if activationState.suppressesActivation(at: Date()) {
            // Step aside during the immediate minimize cascade.
            if let finder = NSRunningApplication.runningApplications(withBundleIdentifier: "com.apple.finder").first {
                finder.activate(options: [.activateIgnoringOtherApps])
            }
            NSApp.hide(nil)
            return
        }
        requestGroupActivation()
    }

    func applicationShouldHandleReopen(
        _ sender: NSApplication,
        hasVisibleWindows flag: Bool
    ) -> Bool {
        // Clicking the Dock tile explicitly requests un-minimizing / restoring the group!
        requestGroupActivation(explicit: true)
        return true
    }

    /// Quits when the controller goes away, by any route.
    ///
    /// A helper with no controller is a Command-Tab entry that can never do
    /// anything. `NSWorkspace.didTerminateApplicationNotification` covers a
    /// normal quit but never arrives when the controller is killed outright, so
    /// the process is watched directly: a dispatch process source fires on any
    /// exit, signal included, and costs nothing while idle.
    private func watchController() {
        guard let controller = NSRunningApplication
            .runningApplications(withBundleIdentifier: controllerBundleID)
            .first(where: { !$0.isTerminated }) else {
            // No controller yet. Quitting on the spot would be wrong during a
            // restart, and would make this helper impossible to exercise on its
            // own, so give it a grace period and re-check.
            DispatchQueue.main.asyncAfter(deadline: .now() + 10) { [weak self] in
                MainActor.assumeIsolated {
                    guard let self else { return }
                    if NSRunningApplication.runningApplications(withBundleIdentifier: controllerBundleID)
                        .contains(where: { !$0.isTerminated }) {
                        self.watchController()
                    } else {
                        self.isFollowingControllerOut = true
                        NSApp.terminate(nil)
                    }
                }
            }
            return
        }
        let source = DispatchSource.makeProcessSource(
            identifier: controller.processIdentifier,
            eventMask: .exit,
            queue: .main
        )
        source.setEventHandler { [weak self] in
            MainActor.assumeIsolated {
                self?.isFollowingControllerOut = true
                NSApp.terminate(nil)
            }
        }
        source.resume()
        controllerExitSource = source
    }

    /// The companion has no windows, so the Dock menu is where per-group actions
    /// belong. Command-Tab activation hands focus away within a moment, which is
    /// why a key handler here could never catch a keystroke.
    func applicationDockMenu(_ sender: NSApplication) -> NSMenu? {
        let menu = NSMenu()
        let show = NSMenuItem(title: "Show Group", action: #selector(showGroup), keyEquivalent: "")
        let minimize = NSMenuItem(title: "Minimize Group", action: #selector(minimizeGroup), keyEquivalent: "")
        for item in [show, minimize] {
            item.target = self
            menu.addItem(item)
        }
        return menu
    }

    @objc private func showGroup() {
        requestGroupActivation(explicit: true)
    }

    @objc private func minimizeGroup() {
        guard !groupID.isEmpty else { return }
        DistributedNotificationCenter.default().postNotificationName(
            minimizeRequest,
            object: groupID,
            userInfo: nil,
            deliverImmediately: true
        )
    }

    private func requestGroupActivation(explicit: Bool = false) {
        guard !groupID.isEmpty else { return }
        // One user action delivers both an activation and a reopen event, so
        // this is reached twice. Uncoalesced, the controller runs the whole
        // restore — rescan, layout write, raise passes — twice per Command-Tab,
        // writing every window's frame twice over.
        guard activationState.beginRequest(at: Date(), explicit: explicit) else { return }

        // Hand our activation right to the controller so its cross-application
        // activation is honoured under macOS 14+ cooperative activation.
        if #available(macOS 14.0, *) {
            NSApp.yieldActivation(toApplicationWithBundleIdentifier: controllerBundleID)
        }

        DistributedNotificationCenter.default().postNotificationName(
            activationRequest,
            object: "\(groupID)|\(ProcessInfo.processInfo.processIdentifier)",
            userInfo: nil,
            deliverImmediately: true
        )

        // If the controller is not running, or the group's windows have all been
        // closed, nothing will take the foreground. Step aside so the user lands
        // back in the application they came from.
        handoffTimeout?.cancel()
        let timeout = DispatchWorkItem { [weak self] in
            self?.handoffCompleted(restored: false)
        }
        handoffTimeout = timeout
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.5, execute: timeout)
    }

    private func handoffCompleted(restored: Bool) {
        handoffTimeout?.cancel()
        handoffTimeout = nil
        // On success the group's own application takes the foreground and there
        // is nothing left to do. On failure this helper is still frontmost with
        // no windows; activating Finder returns focus to the desktop/previous apps.
        guard !restored, NSApp.isActive else { return }
        if let finder = NSRunningApplication.runningApplications(withBundleIdentifier: "com.apple.finder").first {
            finder.activate(options: [.activateIgnoringOtherApps])
        }
        NSApp.hide(nil)
    }

    deinit {
        controllerExitSource?.cancel()
        for observer in observers {
            DistributedNotificationCenter.default().removeObserver(observer)
        }
        if let workspaceObserver {
            NSWorkspace.shared.notificationCenter.removeObserver(workspaceObserver)
        }
    }
}

MainActor.assumeIsolated {
    let application = NSApplication.shared
    let delegate = GroupHostDelegate()
    application.delegate = delegate
    application.run()
}
