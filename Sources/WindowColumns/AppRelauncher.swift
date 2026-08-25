import AppKit
import Foundation

/// Restarts Window Columns in place.
///
/// Accessibility permission granted while the app is running cannot be observed
/// by the running process: `AXIsProcessTrusted()` answers from a cache fixed at
/// launch, so a process that started out denied reports "not trusted" forever.
/// The only way to pick the grant up is to start a new process.
enum AppRelauncher {
    private static let lastRelaunchKey = "WindowColumns.lastAccessibilityRelaunch"

    /// Relaunches at most once per half minute, so a permission that reads as
    /// granted but still does not work can never become a restart loop.
    static func relaunchOnce() {
        let now = Date().timeIntervalSince1970
        let last = UserDefaults.standard.double(forKey: lastRelaunchKey)
        guard now - last > 30 else { return }
        UserDefaults.standard.set(now, forKey: lastRelaunchKey)
        relaunch()
    }

    static func relaunch() {
        let bundlePath = Bundle.main.bundlePath
        let pid = ProcessInfo.processInfo.processIdentifier

        // Wait for this process to be gone before reopening. Launching first and
        // quitting afterwards would briefly run two controllers, and the one
        // shutting down terminates the group companions the other just started.
        let task = Process()
        task.executableURL = URL(fileURLWithPath: "/bin/sh")
        task.arguments = [
            "-c",
            "while kill -0 \(pid) 2>/dev/null; do sleep 0.1; done; sleep 0.3; open \"$0\"",
            bundlePath
        ]
        do {
            try task.run()
        } catch {
            return
        }
        NSApp.terminate(nil)
    }
}
