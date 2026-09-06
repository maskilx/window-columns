import AppKit
import Testing
@testable import WindowColumns

private final class TestDefaults: UserDefaults, @unchecked Sendable {
    let suite: String
    init() {
        suite = "WindowColumnsTests.\(UUID())"
        super.init(suiteName: suite)!
    }
    deinit { removePersistentDomain(forName: suite) }
}

private final class FakeAccessibility: AccessibilityService, @unchecked Sendable {
    var live: [ManagedWindow] = []
    var activePID: pid_t? = 10001
    var focused: AXUIElement?
    var raised: [AXUIElement] = []
    var windowOrder: [CGWindowID] = []
    var minimized: [AXUIElement] = []
    var eventHandler: ((AXUIElement, String) -> Void)?
    var writeHook: ((AXUIElement) -> Void)?

    override var isTrusted: Bool { true }
    override var frontmostPID: pid_t? { activePID }
    override func focusedWindow() -> AXUIElement? { focused }
    override func isFullScreen(_ element: AXUIElement) -> Bool { false }
    override func isMinimized(_ element: AXUIElement) -> Bool { minimized.contains { CFEqual($0, element) } }
    override func minimize(_ element: AXUIElement) { minimized.append(element) }
    override func unminimize(_ element: AXUIElement) { minimized.removeAll { CFEqual($0, element) } }
    override func observe(_ windows: [ManagedWindow], handler: @escaping (AXUIElement, String) -> Void) { eventHandler = handler }
    override func makeFrontmost(pid: pid_t, donorPID: pid_t?) { activePID = pid }
    override func raise(_ element: AXUIElement) {
        raised.append(element)
        if let number = live.first(where: { CFEqual($0.element, element) })?.windowID {
            windowOrder.removeAll { $0 == number }
            windowOrder.insert(number, at: 0)
        }
    }
    override func onScreenWindowOrder() -> [CGWindowID] { windowOrder }
    override func focus(_ element: AXUIElement) { focused = element }
    override func setFrame(_ frame: CGRect, of element: AXUIElement) throws -> CGRect {
        writeHook?(element)
        return frame
    }
    override func discoverWindows(previous: [ManagedWindow], limitedTo: Set<String>?) -> (windows: [ManagedWindow], unsupported: [String]) {
        (live.map { window in
            var copy = window
            copy.isMinimized = isMinimized(copy.element)
            copy.isSelected = previous.first(where: { $0.id == window.id })?.isSelected ?? false
            return copy
        }, [])
    }
}

@Suite(.serialized)
struct ActivationTests {
    @MainActor
    private func fixture() -> (WindowCoordinator, FakeAccessibility, [ManagedWindow], UserDefaults) {
        let service = FakeAccessibility()
        let windows = (0..<5).map { index in
            ManagedWindow(
                id: UUID(), element: AXUIElementCreateApplication(pid_t(20001 + index)),
                windowID: UInt32(index + 1), pid: 10001, appName: "Codex",
                bundleIdentifier: "test.codex", title: "Codex",
                frame: CGRect(x: index * 200, y: 0, width: 200, height: 500),
                minimumSize: CGSize(width: 100, height: 100),
                isMinimized: false, isFullScreen: false, isSelected: false
            )
        }
        service.live = windows
        // An isolated suite avoids reading or changing the user's real groups.
        let defaults = TestDefaults()
        let coordinator = WindowCoordinator(accessibility: service, defaults: defaults, currentDisplays: {
            [DisplayDescriptor(id: "test", name: "Test", visibleFrame: CGRect(x: 0, y: 0, width: 1200, height: 600), scale: 1)]
        })
        coordinator.refresh()
        coordinator.selectedDisplayID = "test"
        return (coordinator, service, windows, defaults)
    }

    @Test
    func testOverlappingSameTitleWindowsReceiveDistinctNumbers() {
        let service = AccessibilityService()
        let frame = CGRect(x: 0, y: 0, width: 800, height: 600)
        let descriptors = [
            AccessibilityService.WindowDescriptor(id: 10, pid: 123, title: "", frame: frame),
            AccessibilityService.WindowDescriptor(id: 11, pid: 123, title: "", frame: frame)
        ]
        let first = service.matchingWindowID(pid: 123, title: "Codex", frame: frame, descriptors: descriptors, excluding: [])!
        let second = service.matchingWindowID(pid: 123, title: "Codex", frame: frame, descriptors: descriptors, excluding: [first])!
        #expect(first != second)
        #expect(service.matchingWindowID(pid: 123, title: "Codex", frame: frame, descriptors: descriptors, excluding: [first, second]) == nil)
    }

    @MainActor
    @Test
    func testStableActivationDoesNotReflowOrReplayFocus() async throws {
        let (coordinator, service, windows, _) = fixture()
        let id = coordinator.createGroup(inOrder: [windows[0].id, windows[1].id])!
        service.live = coordinator.windows
        service.focused = windows[1].element
        var frameWrites = 0
        service.writeHook = { _ in frameWrites += 1 }
        #expect(coordinator.activateGroup(id, activationDonorPID: 10002))
        #expect(service.raised.count == 2)
        #expect(frameWrites == 0)
        try await Task.sleep(nanoseconds: 250_000_000)
        // Electron can deliver our own focus notification after the guard.
        service.eventHandler?(windows[1].element, kAXFocusedWindowChangedNotification as String)
        #expect(service.raised.count == 2)
        #expect(frameWrites == 0)
        coordinator.clearSelection()
    }

    @MainActor
    @Test
    func testPaddingInsetsLayoutAndPreviewWithoutChangingColumnGap() {
        let (coordinator, _, windows, _) = fixture()
        coordinator.windowPadding = 24
        _ = coordinator.createGroup(inOrder: [windows[0].id, windows[1].id])
        let frames = coordinator.selectedWindows.map(\.frame)
        #expect(frames[0].minX == 24)
        #expect(frames[0].minY == 24)
        #expect(frames[1].maxX == 1176)
        #expect(frames[0].maxY == 576)
        #expect(frames[1].minX - frames[0].maxX == 8)
        let preview = coordinator.previewLayout(forOrder: [windows[0].id, windows[1].id])!
        #expect(preview.display.width == 1200)
        #expect(preview.frames == frames)
        coordinator.clearSelection()
    }

    @Test
    func testPaddingPreferencesMigrateAndPersist() throws {
        let old = try JSONDecoder().decode(LayoutPreferences.self, from: Data(#"{"gap":8}"#.utf8))
        #expect(old.windowPadding == 0)
        let saved = LayoutPreferences(windowPadding: 24)
        let restored = try JSONDecoder().decode(LayoutPreferences.self, from: JSONEncoder().encode(saved))
        #expect(restored.windowPadding == 24)
    }

    @MainActor
    @Test
    func testSameAppActivationRaisesEverySiblingAndPreservesFocusedWindow() {
        let (coordinator, service, windows, _) = fixture()
        #expect(coordinator.createGroup(inOrder: [windows[0].id, windows[1].id]) != nil)
        service.focused = windows[0].element
        coordinator.handleApplicationActivated()
        #expect(service.raised.contains(where: { CFEqual($0, windows[0].element) }))
        #expect(service.raised.contains(where: { CFEqual($0, windows[1].element) }))
        #expect(CFEqual(service.focused, windows[0].element))
        coordinator.clearSelection()
    }

    @MainActor
    @Test
    func testFocusedWindowChoosesBetweenGroupsFromSameApp() {
        let (coordinator, service, windows, _) = fixture()
        let first = coordinator.createGroup(inOrder: [windows[0].id, windows[1].id])!
        let second = coordinator.createGroup(inOrder: [windows[2].id, windows[3].id])!
        service.focused = windows[2].element
        coordinator.handleApplicationActivated()
        #expect(coordinator.activeGroupID == second)
        #expect(!service.raised.contains(where: { CFEqual($0, windows[0].element) }))
        coordinator.clearSelection()
        service.raised.removeAll()
        service.focused = windows[0].element
        coordinator.handleApplicationActivated(isFocusChange: true)
        #expect(coordinator.activeGroupID == first)
        #expect(CFEqual(service.focused, windows[0].element))
        coordinator.clearSelection()
    }

    @MainActor
    @Test
    func testUngroupedWindowDoesNotActivateAnotherGroupFromSameApp() {
        let (coordinator, service, windows, _) = fixture()
        _ = coordinator.createGroup(inOrder: [windows[0].id, windows[1].id])
        service.focused = windows[4].element
        coordinator.handleApplicationActivated()
        #expect(service.raised.isEmpty)
        coordinator.clearSelection()
    }

    @MainActor
    @Test
    func testMinimizeGroupLeavesUngroupedSiblingInFrontAndRestoresOnlyMembers() {
        let (coordinator, service, windows, _) = fixture()
        let id = coordinator.createGroup(inOrder: [windows[0].id, windows[1].id])!
        service.focused = windows[1].element
        service.windowOrder = [2, 1, 5]
        #expect(coordinator.minimizeGroup())
        #expect(service.minimized.count == 2)
        #expect(!service.isMinimized(windows[4].element))
        #expect(CFEqual(service.focused, windows[4].element))
        #expect(service.raised.count == 1)
        service.eventHandler?(windows[4].element, kAXFocusedWindowChangedNotification as String)
        #expect(coordinator.isActiveGroupMinimized)
        #expect(service.raised.count == 1)
        service.minimize(windows[4].element)
        #expect(coordinator.activateGroup(id))
        #expect(!service.isMinimized(windows[0].element))
        #expect(!service.isMinimized(windows[1].element))
        #expect(service.isMinimized(windows[4].element))
        coordinator.clearSelection()
    }

    @MainActor
    @Test
    func testMinimizeBackgroundGroupDoesNotStealFocus() {
        let (coordinator, service, windows, _) = fixture()
        let first = coordinator.createGroup(inOrder: [windows[0].id, windows[1].id])!
        let second = coordinator.createGroup(inOrder: [windows[2].id, windows[3].id])!
        service.focused = windows[2].element
        service.windowOrder = [3, 4, 1, 2, 5]
        #expect(coordinator.minimizeGroup(first))
        #expect(CFEqual(service.focused, windows[2].element))
        #expect(service.raised.isEmpty)
        #expect(coordinator.activeGroupID == second)
        #expect(!coordinator.isActiveGroupMinimized)
        coordinator.clearSelection()
    }

    @MainActor
    @Test
    func testMinimizeShortcutDoesNotTargetStaleGroupFromUngroupedWindow() {
        let (coordinator, service, windows, _) = fixture()
        _ = coordinator.createGroup(inOrder: [windows[0].id, windows[1].id])
        service.focused = windows[4].element
        #expect(!coordinator.minimizeGroup())
        #expect(service.minimized.isEmpty)
        coordinator.clearSelection()
    }

    @MainActor
    @Test(arguments: [false, true])
    func testSameAppFocusSwitchCancelsPendingGroupRaise(deliverFocusEvent: Bool) async throws {
        let (coordinator, service, windows, _) = fixture()
        let id = coordinator.createGroup(inOrder: [windows[0].id, windows[1].id])!
        #expect(coordinator.activateGroup(id))
        let raises = service.raised.count
        service.focused = windows[4].element
        service.windowOrder = [5, 2, 1]
        if deliverFocusEvent { coordinator.handleApplicationActivated(isFocusChange: true) }
        try await Task.sleep(nanoseconds: 250_000_000)
        #expect(service.raised.count == raises)
        #expect(CFEqual(service.focused, windows[4].element))
        coordinator.clearSelection()
    }

    @MainActor
    @Test(arguments: [2, 4])
    func testBatchMinimizeNeverResizesMinimizedMembers(count: Int) {
        let (coordinator, service, windows, _) = fixture()
        _ = coordinator.createGroup(inOrder: Array(windows.prefix(4)).map(\.id))
        service.minimized = Array(windows.prefix(count)).map(\.element)
        var writes: [AXUIElement] = []
        service.writeHook = { writes.append($0) }
        service.focused = windows[4].element
        service.eventHandler?(windows[4].element, kAXFocusedWindowChangedNotification as String)
        #expect(!writes.contains { service.isMinimized($0) })
        #expect(coordinator.selectedWindows.count == 4 - count)
        #expect(coordinator.groups.count == (count == 4 ? 0 : 1))
        coordinator.clearSelection()
    }

    @MainActor
    @Test
    func testClosingMiddleMemberPreservesSurvivorProportions() {
        let (coordinator, service, windows, _) = fixture()
        _ = coordinator.createGroup(inOrder: Array(windows.prefix(3)).map(\.id), preferredRatios: [0.2, 0.2, 0.6])
        service.live = [windows[0], windows[2], windows[3], windows[4]]
        service.eventHandler?(windows[1].element, kAXUIElementDestroyedNotification as String)
        #expect(coordinator.selectedWindows.map(\.id) == [windows[0].id, windows[2].id])
        #expect(abs(coordinator.groups[0].ratios[0] - 0.25) < 0.001)
        #expect(abs(coordinator.groups[0].ratios[1] - 0.75) < 0.001)
        coordinator.clearSelection()
    }

    @MainActor
    @Test
    func testClosingMemberOfMinimizedGroupKeepsOtherMembers() {
        let (coordinator, service, windows, _) = fixture()
        let id = coordinator.createGroup(inOrder: Array(windows.prefix(4)).map(\.id))!
        service.focused = windows[4].element
        #expect(coordinator.minimizeGroup(id))
        service.live = Array(windows.dropFirst())
        service.eventHandler?(windows[0].element, kAXUIElementDestroyedNotification as String)
        #expect(coordinator.groups.first?.windows.count == 3)
        #expect(coordinator.isActiveGroupMinimized)
        #expect(service.isMinimized(windows[1].element))
        coordinator.clearSelection()
    }

    @MainActor
    @Test
    func testRegroupingPreservesOriginalGroupProportions() {
        let (coordinator, _, windows, _) = fixture()
        let original = coordinator.createGroup(inOrder: Array(windows.prefix(3)).map(\.id), preferredRatios: [0.2, 0.2, 0.6])!
        _ = coordinator.createGroup(inOrder: [windows[1].id, windows[3].id])
        let remaining = coordinator.groups.first { $0.id == original }!
        #expect(remaining.windows.count == 2)
        #expect(abs(remaining.ratios[0] - 0.25) < 0.001)
        #expect(abs(remaining.ratios[1] - 0.75) < 0.001)
        coordinator.clearSelection()
    }

    @MainActor
    @Test
    func testUpdateDownloadsMatchArchitecture() {
        let arm = UpdateService.GitHubAsset(name: "Window-Columns-v1-macos-arm64.zip", browserDownloadUrl: "https://github.com/arm.zip", size: 100)
        let intel = UpdateService.GitHubAsset(name: "Window-Columns-v1-macos-x86_64.zip", browserDownloadUrl: "https://github.com/intel.zip", size: 100)
        let universal = UpdateService.GitHubAsset(name: "Window-Columns-v1-macos-universal.zip", browserDownloadUrl: "https://github.com/universal.zip", size: 100)
        #expect(UpdateService.downloadURL(from: [arm], architecture: "x86_64") == nil)
        #expect(UpdateService.downloadURL(from: [universal, arm, intel], architecture: "x86_64") == URL(string: intel.browserDownloadUrl))
        #expect(UpdateService.downloadURL(from: [intel, arm], architecture: "arm64") == URL(string: arm.browserDownloadUrl))
        #expect(UpdateService.downloadURL(from: [arm, universal], architecture: "x86_64") == URL(string: universal.browserDownloadUrl))
        let source = UpdateService.GitHubAsset(name: "source.zip", browserDownloadUrl: "https://github.com/source.zip", size: 100)
        let empty = UpdateService.GitHubAsset(name: arm.name, browserDownloadUrl: arm.browserDownloadUrl, size: 0)
        let insecure = UpdateService.GitHubAsset(name: arm.name, browserDownloadUrl: "http://github.com/arm.zip", size: 100)
        #expect(UpdateService.downloadURL(from: [source, empty, insecure], architecture: "arm64") == nil)
    }

    @MainActor
    @Test
    func testIncompleteScanDoesNotShrinkSavedGroup() {
        let (coordinator, service, windows, defaults) = fixture()
        let id = coordinator.createGroup(inOrder: [windows[0].id, windows[1].id, windows[2].id])!
        let saved = defaults.data(forKey: "WindowColumns.windowGroups.v1")
        service.live = Array(windows.prefix(2))
        #expect(coordinator.activateGroup(id))
        // A later screen-change/reconciliation pass must not persist the
        // partial selection left behind by the scan either.
        coordinator.applyCurrentLayout()
        #expect(coordinator.groups.first?.windows.count == 3)
        #expect(defaults.data(forKey: "WindowColumns.windowGroups.v1") == saved)
        #expect(service.raised.contains(where: { CFEqual($0, windows[0].element) }))
        #expect(service.raised.contains(where: { CFEqual($0, windows[1].element) }))
        #expect(!service.raised.contains(where: { CFEqual($0, windows[2].element) }))
        coordinator.clearSelection()
    }

    @MainActor
    @Test
    func testSingleWindowMinimizeDetachesBeforeFocusCanRaiseIt() {
        let (coordinator, service, windows, _) = fixture()
        _ = coordinator.createGroup(inOrder: [windows[0].id, windows[1].id])
        service.minimized = [windows[0].element]
        service.focused = windows[1].element
        service.eventHandler?(windows[1].element, kAXFocusedWindowChangedNotification as String)
        #expect(coordinator.groups.isEmpty)
        #expect(service.raised.isEmpty)
        coordinator.clearSelection()
    }

    @MainActor
    @Test
    func testSavedGroupsNormalizeDuplicateIDsAndExcessSlots() throws {
        let (coordinator, service, windows, defaults) = fixture()
        _ = coordinator.createGroup(inOrder: [windows[0].id, windows[1].id])
        let original = coordinator.groups[0]
        var saved = [original, original]
        for index in 1...10 {
            var copy = original
            copy.id = UUID()
            copy.slot = index + 20
            saved.append(copy)
        }
        defaults.set(try JSONEncoder().encode(saved), forKey: "WindowColumns.windowGroups.v1")
        let loaded = WindowCoordinator(accessibility: service, defaults: defaults)
        #expect(loaded.groups.count == 9)
        #expect(Set(loaded.groups.map(\.id)).count == 9)
        #expect(loaded.groups.map(\.slot) == Array(0..<9))
        coordinator.clearSelection()
    }

    @MainActor
    @Test
    func testCancellingDividerDiscardsQueuedWritesAndStaleCompletion() async throws {
        let (coordinator, service, windows, defaults) = fixture()
        _ = coordinator.createGroup(inOrder: [windows[0].id, windows[1].id])
        let saved = defaults.data(forKey: "WindowColumns.windowGroups.v1")
        let started = DispatchSemaphore(value: 0)
        let release = DispatchSemaphore(value: 0)
        let countLock = NSLock()
        nonisolated(unsafe) var writeCount = 0
        service.writeHook = { _ in
            countLock.lock()
            writeCount += 1
            countLock.unlock()
            started.signal()
            _ = release.wait(timeout: .now() + 2)
        }
        coordinator.dragDivider(after: 0, by: 30)
        let didStart = await withCheckedContinuation { continuation in
            DispatchQueue.global().async {
                continuation.resume(returning: started.wait(timeout: .now() + 2) == .success)
            }
        }
        #expect(didStart)
        coordinator.dragDivider(after: 0, by: 10) // coalesced, queued behind the blocked write
        coordinator.clearSelection()
        var finishCalled = false
        coordinator.finishDividerDrag { finishCalled = true }
        release.signal()
        release.signal() // a broken cancellation path must fail, not hang the test
        try await Task.sleep(nanoseconds: 200_000_000)
        let observedCount = countLock.withLock { writeCount }
        #expect(observedCount == 1)
        #expect(coordinator.selectedWindows.isEmpty)
        #expect(defaults.data(forKey: "WindowColumns.windowGroups.v1") == saved)
        #expect(finishCalled)
    }

    @MainActor
    @Test
    func testSwitchingAwayCancelsDelayedRaises() async throws {
        let (coordinator, service, windows, _) = fixture()
        let id = coordinator.createGroup(inOrder: [windows[0].id, windows[1].id])!
        #expect(coordinator.activateGroup(id, activationDonorPID: 10002))
        let initialRaises = service.raised.count
        service.activePID = 10003
        service.focused = nil
        coordinator.handleApplicationActivated()
        try await Task.sleep(nanoseconds: 300_000_000)
        #expect(service.raised.count == initialRaises)
        coordinator.clearSelection()
    }
}
