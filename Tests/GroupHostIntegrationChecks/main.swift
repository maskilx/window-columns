import AppKit
import Foundation

private let activationRequest = Notification.Name("com.adimaskil.WindowColumns.activateGroup")
private let activationSucceeded = Notification.Name("com.adimaskil.WindowColumns.activateGroup.succeeded")

guard CommandLine.arguments.count == 2 else {
    fputs("Usage: GroupHostIntegrationChecks <helper-app-path>\n", stderr)
    exit(2)
}

let helperURL = URL(fileURLWithPath: CommandLine.arguments[1], isDirectory: true)
guard FileManager.default.fileExists(atPath: helperURL.path) else {
    fputs("Helper app not found: \(helperURL.path)\n", stderr)
    exit(2)
}

guard let helperBundleID = Bundle(url: helperURL)?.bundleIdentifier,
      helperBundleID.hasPrefix("com.adimaskil.WindowColumns.Tests.") else {
    fputs("Use Scripts/test-helper.sh to create an isolated companion; refusing to stop user companions.\n", stderr)
    exit(2)
}

/// The helper declares LSMultipleInstancesProhibited, so a leaked instance from
/// an earlier run is handed back by LaunchServices instead of a fresh one — and
/// it answers with its own, stale group id. Start from a clean slate.
func terminateExistingHelpers() {
    for application in NSRunningApplication.runningApplications(withBundleIdentifier: helperBundleID) {
        _ = application.forceTerminate()
    }
    let deadline = Date().addingTimeInterval(3)
    while !NSRunningApplication.runningApplications(withBundleIdentifier: helperBundleID).isEmpty,
          Date() < deadline {
        RunLoop.current.run(mode: .default, before: Date().addingTimeInterval(0.05))
    }
}
terminateExistingHelpers()

let expectedGroupID = UUID().uuidString
var requestCount = 0
var receivedGroupID: String?
var receivedHelperPID: pid_t?
var launchedApplication: NSRunningApplication?
var launchError: Error?

let observer = DistributedNotificationCenter.default().addObserver(
    forName: activationRequest,
    object: nil,
    queue: .main
) { notification in
    // The helper posts "<group uuid>|<helper pid>" so the controller can use it
    // as the donor for cooperative activation.
    guard let value = notification.object as? String else { return }
    let parts = value.split(separator: "|", maxSplits: 1, omittingEmptySubsequences: false)
    let groupID = String(parts[0])
    let helperPID = parts.count > 1 ? pid_t(String(parts[1])) : nil

    Task { @MainActor in
        requestCount += 1
        receivedGroupID = groupID
        receivedHelperPID = helperPID

        // Stand in for the controller so the helper does not hide itself.
        DistributedNotificationCenter.default().postNotificationName(
            activationSucceeded,
            object: groupID,
            userInfo: nil,
            deliverImmediately: true
        )
    }
}

let configuration = NSWorkspace.OpenConfiguration()
configuration.activates = false
configuration.addsToRecentItems = false
configuration.createsNewApplicationInstance = true
configuration.arguments = [
    "--group-id", expectedGroupID,
    "--group-name", "Integration Test",
    "--ignore-first-activation", "false"
]

NSWorkspace.shared.openApplication(at: helperURL, configuration: configuration) { application, error in
    Task { @MainActor in
        launchedApplication = application
        launchError = error
    }
}

// Background launch must not suppress the first real activation.
let launchDeadline = Date().addingTimeInterval(4)
while launchedApplication == nil, launchError == nil, Date() < launchDeadline {
    RunLoop.current.run(mode: .default, before: Date().addingTimeInterval(0.05))
}
// LaunchServices exercises activation plus Dock reopen. Native Command-Tab
// does not emit reopen and is covered separately by the activation state checks.
// Two things do not work here:
// `NSRunningApplication.activate()` from a background command-line process is
// denied by the same cooperative activation rules this app exists to work
// around, and `open -b` cannot resolve the bundle identifier because helpers
// nested in Contents/Helpers are not registered with LaunchServices until the
// controller launches one. Opening the bundle by path avoids both.
let activation = Process()
activation.executableURL = URL(fileURLWithPath: "/usr/bin/open")
activation.arguments = [helperURL.path]
try? activation.run()
activation.waitUntilExit()

let activationDeadline = Date().addingTimeInterval(6)
while receivedGroupID == nil, launchError == nil, Date() < activationDeadline {
    RunLoop.current.run(mode: .default, before: Date().addingTimeInterval(0.05))
}

/// `exit()` does not unwind, so a `defer` here would never run and a failing
/// run would leak the helper it launched — poisoning every subsequent run.
func fail(_ message: String) -> Never {
    DistributedNotificationCenter.default().removeObserver(observer)
    terminateExistingHelpers()
    fputs(message + "\n", stderr)
    exit(1)
}

if let launchError {
    fail("Group helper failed to launch: \(launchError)")
}
guard receivedGroupID == expectedGroupID else {
    fail("Activation notification mismatch. Expected \(expectedGroupID), received \(receivedGroupID ?? "none")")
}
guard let launchedApplication else {
    fail("Group helper launched without an NSRunningApplication handle")
}
guard receivedHelperPID == launchedApplication.processIdentifier else {
    fail(
        "Activation notification carried helper pid \(receivedHelperPID.map(String.init) ?? "none"), "
            + "expected \(launchedApplication.processIdentifier)"
    )
}

RunLoop.current.run(until: Date().addingTimeInterval(0.5))
guard requestCount == 1 else {
    fail("A single activation sent \(requestCount) restore requests")
}

_ = launchedApplication.forceTerminate()
let terminationDeadline = Date().addingTimeInterval(3)
while !launchedApplication.isTerminated, Date() < terminationDeadline {
    RunLoop.current.run(mode: .default, before: Date().addingTimeInterval(0.05))
}
guard launchedApplication.isTerminated else {
    fail("Group helper did not terminate")
}
DistributedNotificationCenter.default().removeObserver(observer)

print("Group helper activation handshake and termination checks passed.")
