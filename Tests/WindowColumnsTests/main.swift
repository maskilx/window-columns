import CoreGraphics
import Foundation
import WindowColumnsCore

private func approximatelyEqual(_ lhs: CGFloat, _ rhs: CGFloat) -> Bool {
    abs(lhs - rhs) < 0.001
}

@main
struct LayoutEngineChecks {
    static func main() throws {
        let outer = CGRect(x: -1500, y: 400, width: 1200, height: 900)
        precondition(ColumnLayoutEngine.contentFrame(in: outer, padding: 24) == outer.insetBy(dx: 24, dy: 24))
        precondition(ColumnLayoutEngine.contentFrame(in: outer, padding: 0) == outer)
        precondition(ColumnLayoutEngine.contentFrame(in: outer, padding: -.infinity) == outer)
        precondition(ColumnLayoutEngine.contentFrame(in: outer, padding: 10000).height > 0)
        let equal = try ColumnLayoutEngine.frames(
            in: CGRect(x: 0, y: 25, width: 1000, height: 500),
            ratios: [1, 1, 1], minimumWidths: [100, 100, 100], gap: 10
        )
        precondition(equal.count == 3)
        precondition(approximatelyEqual(equal[1].minX - equal[0].maxX, 10))
        precondition(approximatelyEqual(equal[2].maxX, 1000))
        precondition(equal.allSatisfy { $0.minY == 25 && $0.height == 500 })

        let constrained = try ColumnLayoutEngine.frames(
            in: CGRect(x: 0, y: 0, width: 900, height: 500),
            ratios: [0.1, 0.45, 0.45], minimumWidths: [200, 100, 100], gap: 0
        )
        precondition(approximatelyEqual(constrained[0].width, 200))
        precondition(approximatelyEqual(constrained[1].width, 350))
        precondition(approximatelyEqual(constrained[2].width, 350))

        do {
            _ = try ColumnLayoutEngine.frames(
                in: CGRect(x: 0, y: 0, width: 500, height: 500),
                ratios: [1, 1], minimumWidths: [300, 300], gap: 8
            )
            preconditionFailure("Expected an insufficient-space error")
        } catch ColumnLayoutError.insufficientSpace {}

        let grown = ColumnLayoutEngine.adjustedRatios(
            afterResizing: 0, to: 500,
            currentWidths: [300, 300, 300], minimumWidths: [150, 250, 150]
        ).map { $0 * 900 }
        precondition(approximatelyEqual(grown[0], 500))
        precondition(approximatelyEqual(grown[1], 250))
        precondition(approximatelyEqual(grown[2], 150))

        let shrunk = ColumnLayoutEngine.adjustedRatios(
            afterResizing: 1, to: 200,
            currentWidths: [300, 300, 300], minimumWidths: [100, 100, 100]
        ).map { $0 * 900 }
        precondition(approximatelyEqual(shrunk[1], 200))
        precondition(approximatelyEqual(shrunk[2], 400))

        let rightDivider = ColumnLayoutEngine.adjustedRatios(
            movingDividerAfter: 1, by: 80,
            currentWidths: [300, 300, 300], minimumWidths: [150, 150, 250]
        ).map { $0 * 900 }
        precondition(approximatelyEqual(rightDivider[0], 300))
        precondition(approximatelyEqual(rightDivider[1], 350))
        precondition(approximatelyEqual(rightDivider[2], 250))

        let leftDivider = ColumnLayoutEngine.adjustedRatios(
            movingDividerAfter: 0, by: -90,
            currentWidths: [300, 300, 300], minimumWidths: [240, 150, 150]
        ).map { $0 * 900 }
        precondition(approximatelyEqual(leftDivider[0], 240))
        precondition(approximatelyEqual(leftDivider[1], 360))
        precondition(approximatelyEqual(leftDivider[2], 300))

        let slots = [
            CGRect(x: 0, y: 0, width: 300, height: 500),
            CGRect(x: 310, y: 0, width: 300, height: 500),
            CGRect(x: 620, y: 0, width: 300, height: 500)
        ]
        precondition(ColumnLayoutEngine.nearestColumnIndex(to: 158, in: slots) == 0)
        precondition(ColumnLayoutEngine.nearestColumnIndex(to: 465, in: slots) == 1)
        precondition(ColumnLayoutEngine.nearestColumnIndex(to: 780, in: slots) == 2)
        precondition(ColumnLayoutEngine.nearestColumnIndex(to: 608, in: slots) == 1)

        checkWindowMatching()
        checkCompanionLaunchGate()
        checkCompanionActivationState()
        checkFingerprintMatching()
        checkDisplacementClassification()
        checkFit()
        checkGroupMinimizationState()
        checkSemanticVersion()

        print("All core checks passed.")
    }

    private static func checkGroupMinimizationState() {
        var state = GroupMinimizationState<String>()

        state.minimize("background")
        precondition(state.contains("background"))
        precondition(!state.containsActiveGroup("selected"))

        state.minimize("selected")
        precondition(state.containsActiveGroup("selected"))

        // Restoring one group must not release another group's minimized state.
        state.restore("selected")
        precondition(!state.containsActiveGroup("selected"))
        precondition(state.contains("background"))

        // Deleted group records must not leave stale minimization state behind.
        state.retain(only: ["selected"])
        precondition(!state.contains("background"))
    }

    private static func checkFit() {
        // Two ordinary windows on a 1512 pt display with an 8 pt gap.
        let easy = ColumnLayoutEngine.fit(in: 1512, minimumWidths: [160, 160], gap: 8)
        precondition(easy.fits)
        precondition(approximatelyEqual(easy.available, 1504))

        // A window that will not go below 900 still fits beside a small one.
        precondition(ColumnLayoutEngine.fit(in: 1512, minimumWidths: [900, 160], gap: 8).fits)

        // Two wide-minimum windows do not, and the shortfall is reported so the
        // message can say by how much.
        let tight = ColumnLayoutEngine.fit(in: 1512, minimumWidths: [900, 800], gap: 8)
        precondition(!tight.fits)
        precondition(approximatelyEqual(tight.overflow, 196))

        // Exactly filling the display counts as fitting.
        precondition(ColumnLayoutEngine.fit(in: 1000, minimumWidths: [496, 496], gap: 8).fits)

        // Gaps consume real space: nine windows pay for eight of them, leaving
        // 1448 pt — which nine 160 pt windows still just fit inside.
        let many = ColumnLayoutEngine.fit(in: 1512, minimumWidths: Array(repeating: 160, count: 9), gap: 8)
        precondition(approximatelyEqual(many.available, 1512 - 64))
        precondition(many.fits)
        // At 200 pt each they no longer do.
        precondition(!ColumnLayoutEngine.fit(in: 1512, minimumWidths: Array(repeating: 200, count: 9), gap: 8).fits)

        // A single window has no gaps to pay for.
        precondition(approximatelyEqual(
            ColumnLayoutEngine.fit(in: 800, minimumWidths: [300], gap: 12).available, 800
        ))
    }

    private static func checkDisplacementClassification() {
        let slot = CGRect(x: 100, y: 0, width: 400, height: 900)

        // Exactly in place, and sub-pixel jitter, must never trigger a write.
        precondition(ColumnDisplacement(actual: slot, target: slot) == .inPlace)
        precondition(
            ColumnDisplacement(actual: slot.offsetBy(dx: 1, dy: -1), target: slot) == .inPlace
        )

        // Dragged sideways, dragged down, and a small nudge are all moves.
        precondition(
            ColumnDisplacement(actual: slot.offsetBy(dx: 500, dy: 0), target: slot) == .moved
        )
        precondition(
            ColumnDisplacement(actual: slot.offsetBy(dx: 0, dy: -300), target: slot) == .moved
        )
        precondition(
            ColumnDisplacement(actual: slot.offsetBy(dx: 6, dy: 0), target: slot) == .moved
        )

        // A resize must be reported as a resize, never as a move, or snapping
        // back would discard it. This holds even when the origin also shifted,
        // which is what dragging a left or top edge does.
        precondition(
            ColumnDisplacement(
                actual: CGRect(x: 100, y: 0, width: 560, height: 900), target: slot
            ) == .resized
        )
        precondition(
            ColumnDisplacement(
                actual: CGRect(x: 40, y: 0, width: 460, height: 900), target: slot
            ) == .resized
        )
        precondition(
            ColumnDisplacement(
                actual: CGRect(x: 100, y: 200, width: 400, height: 700), target: slot
            ) == .resized
        )
    }

    private static func checkCompanionActivationState() {
        var state = CompanionActivationState()
        let now = Date(timeIntervalSince1970: 100)
        precondition(state.beginRequest(at: now), "The first Command-Tab must work immediately after launch")
        precondition(!state.beginRequest(at: now.addingTimeInterval(0.1), explicit: true), "Dock reopen coalesces with activation")
        state.didMinimize(at: now.addingTimeInterval(1))
        precondition(!state.beginRequest(at: now.addingTimeInterval(1.1)), "Suppress the minimize cascade")
        precondition(state.beginRequest(at: now.addingTimeInterval(1.4)), "Command-Tab restores a minimized group")
        state.didMinimize(at: now.addingTimeInterval(2))
        precondition(state.beginRequest(at: now.addingTimeInterval(2.01), explicit: true), "Show Group bypasses cascade suppression")
    }

    private static func checkCompanionLaunchGate() {
        var gate = CompanionLaunchGate<String>()
        let now = Date(timeIntervalSince1970: 100)
        let first = gate.begin("group", now: now)!
        precondition(gate.begin("group", now: now) == nil, "Repeated sync must not launch twice")
        precondition(gate.begin("other", now: now) != nil, "Groups launch independently")
        gate.cancel("group")
        let replacement = gate.begin("group", now: now)!
        precondition(!gate.complete("group", token: first), "Deleted/renumbered launch callback is stale")
        precondition(gate.isPending("group"), "Stale completion must not consume the replacement")
        precondition(gate.complete("group", token: replacement))
        gate.deferRetry("group", until: now.addingTimeInterval(30))
        precondition(gate.begin("group", now: now.addingTimeInterval(29)) == nil,
                     "Reconciliation must not bypass crash backoff")
        precondition(gate.retryDelay(for: "group", now: now) == 30)
        precondition(gate.begin("group", now: now.addingTimeInterval(30)) != nil)
    }

    private static func checkWindowMatching() {
        func identity(_ bundle: String, _ title: String, _ number: UInt32?) -> WindowIdentity {
            WindowIdentity(bundleIdentifier: bundle, title: title, windowNumber: number)
        }

        // Exact WindowServer numbers win, and the saved order is preserved even
        // when the live list is ordered differently.
        let saved = [
            identity("com.brave.Browser", "Docs", 41),
            identity("com.apple.dt.Xcode", "Project", 12)
        ]
        let live = [
            identity("com.apple.dt.Xcode", "Project", 12),
            identity("com.brave.Browser", "Mail", 77),
            identity("com.brave.Browser", "Docs", 41)
        ]
        precondition(WindowMatcher.resolve(saved: saved, available: live) == [2, 0])

        // An application that restarted has new window numbers; the title still
        // identifies the window.
        let restarted = [
            identity("com.apple.dt.Xcode", "Project", 900),
            identity("com.brave.Browser", "Docs", 901)
        ]
        precondition(WindowMatcher.resolve(saved: saved, available: restarted) == [1, 0])

        // A stale number must never steal a window that an exact match needs:
        // entry 1 claims its exact window, and only then does the numberless
        // entry fall back to Brave's one remaining window.
        let staleFirst = [
            identity("com.brave.Browser", "Docs", nil),
            identity("com.brave.Browser", "Docs", 41)
        ]
        precondition(WindowMatcher.resolve(saved: staleFirst, available: live) == [1, 2])

        // Two windows of one application with the same title: both are claimed,
        // one each, rather than one of them matching twice.
        let duplicates = [
            identity("com.brave.Browser", "Untitled", 5),
            identity("com.brave.Browser", "Untitled", 6)
        ]
        let renumbered = [
            identity("com.brave.Browser", "Untitled", 88),
            identity("com.brave.Browser", "Untitled", 89)
        ]
        precondition(WindowMatcher.resolve(saved: duplicates, available: renumbered) == [0, 1])

        // Last resort: the application reopened with new numbers and new titles.
        // Two saved entries, two live windows, so they pair up in order.
        let retitled = [
            identity("com.brave.Browser", "Something Else", 300),
            identity("com.brave.Browser", "Another Page", 301)
        ]
        precondition(WindowMatcher.resolve(saved: duplicates, available: retitled) == [0, 1])

        // Counts disagree, so the last resort refuses to guess rather than
        // dragging an unrelated window of the same application into the group.
        let ambiguous = [
            identity("com.brave.Browser", "A", 300),
            identity("com.brave.Browser", "B", 301),
            identity("com.brave.Browser", "C", 302)
        ]
        precondition(
            WindowMatcher.resolve(saved: [identity("com.brave.Browser", "Docs", 41)], available: ambiguous).isEmpty
        )

        // A window that is simply gone yields a shorter result, never a wrong one.
        precondition(
            WindowMatcher.resolve(saved: saved, available: [identity("com.apple.dt.Xcode", "Project", 12)]) == [0]
        )
    }

    private static func checkFingerprintMatching() {
        let original = WindowFingerprint(bundleIdentifier: "com.brave.Browser", title: "Original Title", windowNumber: 101)
        let retitled = WindowFingerprint(bundleIdentifier: "com.brave.Browser", title: "New Tab — GitHub", windowNumber: 101)
        let otherWindowSameApp = WindowFingerprint(bundleIdentifier: "com.brave.Browser", title: "Original Title", windowNumber: 102)
        let differentApp = WindowFingerprint(bundleIdentifier: "com.apple.Safari", title: "Original Title", windowNumber: 101)

        // Same bundle ID and window number matches even if title changes (e.g. web navigation)
        precondition(original.matches(retitled))
        precondition(retitled.matches(original))

        // Different window numbers do not match
        precondition(!original.matches(otherWindowSameApp))

        // Different bundle IDs never match
        precondition(!original.matches(differentApp))

        // When numbers are missing (e.g. app restarted), title is required
        let unnumbered1 = WindowFingerprint(bundleIdentifier: "com.brave.Browser", title: "Docs", windowNumber: nil)
        let unnumbered2 = WindowFingerprint(bundleIdentifier: "com.brave.Browser", title: "Docs", windowNumber: nil)
        let unnumbered3 = WindowFingerprint(bundleIdentifier: "com.brave.Browser", title: "Other", windowNumber: nil)
        precondition(unnumbered1.matches(unnumbered2))
        precondition(!unnumbered1.matches(unnumbered3))
    }

    private static func checkSemanticVersion() {
        guard let v1 = SemanticVersion(string: "0.1.0-beta.1"),
              let v2 = SemanticVersion(string: "v0.1.0-beta.2"),
              let v10 = SemanticVersion(string: "0.1.0-beta.10"),
              let vRelease = SemanticVersion(string: "0.1.0"),
              let vPatch = SemanticVersion(string: "0.1.1"),
              let vMinor = SemanticVersion(string: "0.2.0"),
              let vBuild = SemanticVersion(string: "0.1.0-beta.2+build.123") else {
            preconditionFailure("Failed to parse semantic versions")
        }

        // Parsing checks
        precondition(v2.major == 0 && v2.minor == 1 && v2.patch == 0)
        precondition(v2.isPrerelease)
        precondition(!vRelease.isPrerelease)

        // Equalities (ignoring 'v' prefix and build metadata)
        precondition(v2 == vBuild)
        precondition(SemanticVersion(string: "0.1.0-beta.2") == v2)

        // Comparisons: SemVer 2.0 precedence
        precondition(v1 < v2)
        precondition(v2 < v10) // numeric ordering: 2 < 10
        precondition(v10 < vRelease) // prerelease < normal release
        precondition(vRelease < vPatch)
        precondition(vPatch < vMinor)

        // Textual vs numeric prerelease
        guard let alpha = SemanticVersion(string: "1.0.0-alpha"),
              let alpha1 = SemanticVersion(string: "1.0.0-alpha.1"),
              let alphaBeta = SemanticVersion(string: "1.0.0-alpha.beta"),
              let beta = SemanticVersion(string: "1.0.0-beta"),
              let beta2 = SemanticVersion(string: "1.0.0-beta.2"),
              let rc = SemanticVersion(string: "1.0.0-rc.1"),
              let normal = SemanticVersion(string: "1.0.0") else {
            preconditionFailure("Failed to parse SemVer 2.0 sequence")
        }
        precondition(alpha < alpha1)
        precondition(alpha1 < alphaBeta)
        precondition(alphaBeta < beta)
        precondition(beta < beta2)
        precondition(beta2 < rc)
        precondition(rc < normal)

        // AppVersion checks
        precondition(AppVersion.current == "0.1.0-beta.4")
        precondition(AppVersion.semantic == SemanticVersion(string: "0.1.0-beta.4")!)

        // JSON Codable roundtrip
        do {
            let data = try JSONEncoder().encode(v2)
            let decoded = try JSONDecoder().decode(SemanticVersion.self, from: data)
            precondition(decoded == v2)
        } catch {
            preconditionFailure("JSON Codable failed for SemanticVersion: \(error)")
        }
    }
}
