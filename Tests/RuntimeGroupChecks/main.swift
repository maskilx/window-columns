import AppKit
import CoreGraphics
import Foundation

// End-to-end verification against the installed app and the real window server.
//
// Everything here is observation plus LaunchServices activation, so it needs no
// Accessibility or Automation grant of its own. Anything that requires
// synthesizing input is out of scope: macOS only lets an Accessibility-trusted
// process post events.

let controllerBundleID = "com.adimaskil.WindowColumns"
var failures: [String] = []
var checks = 0

func check(_ name: String, _ condition: Bool, _ detail: @autoclosure () -> String = "") {
    checks += 1
    if condition {
        print("  ok    \(name)")
    } else {
        let extra = detail()
        print("  FAIL  \(name)\(extra.isEmpty ? "" : " — \(extra)")")
        failures.append(name)
    }
}

func wait(timeout: TimeInterval, until condition: () -> Bool) -> Bool {
    let deadline = Date().addingTimeInterval(timeout)
    while !condition(), Date() < deadline {
        RunLoop.current.run(mode: .default, before: Date().addingTimeInterval(0.05))
    }
    return condition()
}

struct OnScreenWindow {
    let number: CGWindowID
    let ownerPID: pid_t
    let owner: String
    /// Top-left origin, as the window server reports it.
    let bounds: CGRect
}

func onScreenWindows() -> [OnScreenWindow] {
    let info = CGWindowListCopyWindowInfo(
        [.optionOnScreenOnly, .excludeDesktopElements],
        kCGNullWindowID
    ) as? [[String: Any]] ?? []
    return info.compactMap { item in
        guard (item[kCGWindowLayer as String] as? NSNumber)?.intValue == 0,
              let number = item[kCGWindowNumber as String] as? NSNumber,
              let pid = item[kCGWindowOwnerPID as String] as? NSNumber,
              let boundsDictionary = item[kCGWindowBounds as String] as? NSDictionary,
              let bounds = CGRect(dictionaryRepresentation: boundsDictionary) else { return nil }
        return OnScreenWindow(
            number: CGWindowID(number.uint32Value),
            ownerPID: pid_t(pid.int32Value),
            owner: item[kCGWindowOwnerName as String] as? String ?? "?",
            bounds: bounds
        )
    }
}

struct SavedGroup {
    let slot: Int
    let name: String
    let customName: String?
    let colorIndex: Int
    let gap: Double
    let windowNumbers: [CGWindowID]
    let bundleIDs: [String]
}

func savedGroups() -> [SavedGroup] {
    guard let defaults = UserDefaults(suiteName: controllerBundleID),
          let data = defaults.data(forKey: "WindowColumns.windowGroups.v1"),
          let raw = try? JSONSerialization.jsonObject(with: data) as? [[String: Any]] else { return [] }
    return raw.compactMap { item in
        guard let slot = item["slot"] as? Int,
              let windows = item["windows"] as? [[String: Any]] else { return nil }
        return SavedGroup(
            slot: slot,
            name: item["name"] as? String ?? "?",
            customName: item["customName"] as? String,
            colorIndex: item["colorIndex"] as? Int ?? -1,
            gap: item["gap"] as? Double ?? 8,
            windowNumbers: windows.compactMap {
                ($0["windowNumber"] as? NSNumber).map { CGWindowID($0.uint32Value) }
            },
            bundleIDs: windows.compactMap { $0["bundleIdentifier"] as? String }
        )
    }.sorted { $0.slot < $1.slot }
}

/// The usable area in the window server's top-left coordinate space.
func visibleFrameTopLeft(for screen: NSScreen) -> CGRect {
    let full = screen.frame
    let visible = screen.visibleFrame
    return CGRect(
        x: visible.minX,
        y: full.height - visible.maxY,
        width: visible.width,
        height: visible.height
    )
}

func activate(bundleID: String) {
    let task = Process()
    task.executableURL = URL(fileURLWithPath: "/usr/bin/open")
    task.arguments = ["-b", bundleID]
    try? task.run()
    task.waitUntilExit()
}

// MARK: - Controller and companions

print("\n[1] Controller and companions")
let controllers = NSRunningApplication.runningApplications(withBundleIdentifier: controllerBundleID)
check("controller is running", controllers.count == 1, "found \(controllers.count)")
guard let controller = controllers.first else {
    print("\nCannot continue without the controller. Launch Window Columns and retry.")
    exit(1)
}

let groups = savedGroups()
check("at least one saved group to exercise", !groups.isEmpty)

for group in groups {
    let companions = NSRunningApplication.runningApplications(
        withBundleIdentifier: "\(controllerBundleID).Group\(group.slot + 1)"
    )
    check("group \(group.slot + 1) has exactly one companion", companions.count == 1, "found \(companions.count)")
}
for slot in 0..<9 where !groups.contains(where: { $0.slot == slot }) {
    let stray = NSRunningApplication.runningApplications(
        withBundleIdentifier: "\(controllerBundleID).Group\(slot + 1)"
    )
    check("no orphan companion in unused slot \(slot + 1)", stray.isEmpty)
}

// MARK: - Activation brings the real windows forward

print("\n[2] Command-Tab style activation")
guard let screen = NSScreen.main else { exit(1) }
let usable = visibleFrameTopLeft(for: screen)

for group in groups {
    let label = "group \(group.slot + 1)"
    guard group.windowNumbers.count >= 2 else {
        check("\(label) has at least two saved windows", false)
        continue
    }

    // Put an unrelated application in front first, so activation has real work.
    if let other = NSWorkspace.shared.runningApplications.first(where: {
        $0.activationPolicy == .regular
            && $0.processIdentifier != controller.processIdentifier
            && !group.bundleIDs.contains($0.bundleIdentifier ?? "")
            && $0.bundleIdentifier?.hasPrefix(controllerBundleID) == false
    }) {
        activate(bundleID: other.bundleIdentifier ?? "")
        _ = wait(timeout: 2) {
            NSWorkspace.shared.frontmostApplication?.processIdentifier == other.processIdentifier
        }
    }

    // This is what Command-Tab does: select the companion.
    let companionBundleID = "\(controllerBundleID).Group\(group.slot + 1)"
    activate(bundleID: companionBundleID)

    let expected = Set(group.windowNumbers)
    let allVisible = wait(timeout: 5) {
        let visible = Set(onScreenWindows().map(\.number))
        return expected.isSubset(of: visible)
    }
    check("\(label): every member window is on screen after activation", allVisible)

    // The companion must hand over rather than sit in front with no windows.
    let companionPID = NSRunningApplication
        .runningApplications(withBundleIdentifier: companionBundleID)
        .first?.processIdentifier
    let handedOver = wait(timeout: 3) {
        NSWorkspace.shared.frontmostApplication?.processIdentifier != companionPID
    }
    check("\(label): companion yielded the foreground", handedOver,
          "frontmost is \(NSWorkspace.shared.frontmostApplication?.localizedName ?? "?")")

    // Position 1 is the last saved window; its application should be frontmost.
    if let mainBundleID = group.bundleIDs.last {
        let focused = wait(timeout: 3) {
            NSWorkspace.shared.frontmostApplication?.bundleIdentifier == mainBundleID
        }
        check("\(label): position 1's application is frontmost", focused,
              "expected \(mainBundleID), got \(NSWorkspace.shared.frontmostApplication?.bundleIdentifier ?? "?")")
    }

    // MARK: Geometry — a connected set of full-height columns.
    RunLoop.current.run(until: Date().addingTimeInterval(0.4))
    let windows = onScreenWindows()
    let members = group.windowNumbers.compactMap { number in
        windows.first { $0.number == number }
    }
    guard members.count == group.windowNumbers.count else {
        check("\(label): all members measurable", false, "found \(members.count)")
        continue
    }
    let columns = members.map(\.bounds).sorted { $0.minX < $1.minX }
    let tolerance: CGFloat = 4

    check("\(label): leftmost column starts at the usable area",
          abs(columns[0].minX - usable.minX) <= tolerance,
          "\(columns[0].minX) vs \(usable.minX)")
    check("\(label): rightmost column ends at the usable area",
          abs(columns[columns.count - 1].maxX - usable.maxX) <= tolerance,
          "\(columns[columns.count - 1].maxX) vs \(usable.maxX)")
    check("\(label): every column is full height",
          columns.allSatisfy {
              abs($0.minY - usable.minY) <= tolerance && abs($0.height - usable.height) <= tolerance
          },
          columns.map { "y\(Int($0.minY)) h\(Int($0.height))" }.joined(separator: " "))

    var gapsCorrect = true
    var observedGaps: [String] = []
    for index in 0..<(columns.count - 1) {
        let gap = columns[index + 1].minX - columns[index].maxX
        observedGaps.append(String(format: "%.0f", gap))
        if abs(gap - CGFloat(group.gap)) > tolerance { gapsCorrect = false }
    }
    check("\(label): columns are separated by the configured \(Int(group.gap))px gap",
          gapsCorrect, "observed \(observedGaps.joined(separator: ", "))")
    check("\(label): columns do not overlap",
          (0..<(columns.count - 1)).allSatisfy { columns[$0].maxX <= columns[$0 + 1].minX + tolerance })
}

// MARK: - Group identity

print("\n[3] Group identity")
for group in groups {
    let expectedDefault = "Group \(group.slot + 1)"
    if let custom = group.customName {
        check("group \(group.slot + 1): custom name '\(custom)' survived persistence",
              group.name == custom, "name is '\(group.name)'")
    } else {
        check("group \(group.slot + 1): default name tracks its slot",
              group.name == expectedDefault, "name is '\(group.name)'")
    }
    check("group \(group.slot + 1): colour index is within the nine-colour palette",
          (0..<9).contains(group.colorIndex), "colorIndex \(group.colorIndex)")
    check("group \(group.slot + 1): colour index matches its slot",
          group.colorIndex == group.slot % 9, "colorIndex \(group.colorIndex) slot \(group.slot)")
}

// MARK: - Report

print("\n\(checks - failures.count)/\(checks) checks passed")
if failures.isEmpty {
    print("Runtime end-to-end checks passed.")
} else {
    print("Failed:")
    failures.forEach { print("  - \($0)") }
    exit(1)
}
