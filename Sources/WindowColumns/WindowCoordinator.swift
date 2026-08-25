import AppKit
import ApplicationServices
import Foundation
import WindowColumnsCore

private struct DividerFrameWrite: @unchecked Sendable {
    let windowID: UUID
    let element: AXUIElement
    let target: CGRect
}

private struct PendingFrameEvent {
    let element: AXUIElement
    var wasMoved: Bool
    var wasResized: Bool
}

/// Where a set of windows sat before an arrangement moved them.
private struct ArrangementUndo {
    struct Entry {
        let windowID: UUID
        let element: AXUIElement
        let frame: CGRect
    }
    let entries: [Entry]
    /// Set when the arrangement created the group, which undo then dismantles.
    let createdGroupID: UUID?
    let groupName: String
    let capturedAt: Date
}

private struct SuppressedFrameEvent {
    let expires: Date
    let target: CGRect
}

@MainActor
final class WindowCoordinator: ObservableObject {
    @Published private(set) var windows: [ManagedWindow] = []
    @Published private(set) var unsupportedWindows: [String] = []
    @Published var displays: [DisplayDescriptor] = DisplayDescriptor.current()
    @Published var selectedDisplayID: String = ""
    @Published var gap: Double = 8
    @Published var lastError: LayoutError?
    @Published var isApplyingLayout = false
    @Published private(set) var accessibilityGranted = false
    @Published private(set) var permissionStatusMessage = ""
    @Published private(set) var groups: [WindowGroupSnapshot] = []
    @Published private(set) var activeGroupID: UUID?

    private let accessibility: AccessibilityService
    private var ratios: [CGFloat] = []
    private var selectionOrder: [UUID] = []
    private var pendingResize: DispatchWorkItem?
    private var pendingFrameEvents: [UUID: PendingFrameEvent] = [:]
    private var suppressedFrameEvents: [UUID: SuppressedFrameEvent] = [:]
    private var pendingSwap: (windowID: UUID, targetIndex: Int)?
    private var dividerDragSession: (divider: Int, widths: [CGFloat], totalDelta: CGFloat)?
    private let dividerWriteQueue = DispatchQueue(
        label: "com.adimaskil.WindowColumns.divider-writes",
        qos: .userInteractive
    )
    private var pendingDividerWrites: [DividerFrameWrite]?
    private var dividerWriteInFlight = false
    private var finishDividerWhenWritesComplete = false
    private var dividerFinishCompletion: (() -> Void)?
    private var mouseUpMonitor: Any?
    private var mouseDownMonitor: Any?
    private var pointerDownLocation: CGPoint?
    private var groupVerificationWorkItem: DispatchWorkItem?
    private var interactionNeedsReconciliation = false
    private var interactionFinishWorkItem: DispatchWorkItem?
    private var layoutReconciliationWorkItem: DispatchWorkItem?
    private var screenChangeWorkItem: DispatchWorkItem?
    private var arrangementUndo: ArrangementUndo?
    private var screenObserver: NSObjectProtocol?
    private var foregroundActivationGeneration = 0
    /// Groups deliberately held minimized. This is tracked per group because a
    /// Dock-menu request can minimize a background group while another group is
    /// selected and must remain fully interactive.
    ///
    /// For the selected group, several paths would otherwise put its windows
    /// straight back: every layout write clears `AXMinimized`, minimizing emits
    /// move and resize notifications that drive reconciliation, and the
    /// pointer-release check reads a minimized window's stale frame and calls it
    /// displaced.
    private var minimizedGroups = GroupMinimizationState<UUID>()
    private let groupsKey = "WindowColumns.windowGroups.v1"
    var onLayoutStateChanged: ((Bool) -> Void)?
    var onGroupsChanged: (([WindowGroupSnapshot]) -> Void)?
    var onLayoutFramesChanged: (([CGRect]) -> Void)?
    var onFrontmostWindowChanged: (() -> Void)?
    var onGroupRenamed: ((WindowGroupSnapshot) -> Void)?

    init(accessibility: AccessibilityService = AccessibilityService()) {
        self.accessibility = accessibility
        // Build 18 removes the old implicit workspace restore mechanism.
        UserDefaults.standard.removeObject(forKey: "WindowColumns.automaticWorkspaces.v1")
        accessibilityGranted = accessibility.isTrusted
        selectedDisplayID = displays.first?.id ?? ""
        if let data = UserDefaults.standard.data(forKey: groupsKey),
           let saved = try? JSONDecoder().decode([WindowGroupSnapshot].self, from: data) {
            groups = saved.compactMap { snapshot in
                var normalized = snapshot
                normalized.windows = uniquePreservingOrder(snapshot.windows)
                guard normalized.windows.count >= 2 else { return nil }
                // The chooser offers 0…32, but a corrupt or hand-edited value
                // would leave the group permanently impossible to lay out.
                normalized.gap = min(max(normalized.gap, 0), 64)
                if normalized.ratios.count != normalized.windows.count {
                    normalized.ratios = Array(
                        repeating: 1 / Double(normalized.windows.count),
                        count: normalized.windows.count
                    )
                }
                return normalized
            }.sorted { $0.slot < $1.slot }
            for index in groups.indices {
                groups[index].slot = index
                groups[index].colorIndex = index % GroupPalette.count
                groups[index].name = groups[index].customName ?? "Group \(index + 1)"
            }
        }
        screenObserver = NotificationCenter.default.addObserver(
            forName: NSApplication.didChangeScreenParametersNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            Task { @MainActor in self?.handleScreenParametersChanged() }
        }
    }

    deinit {
        if let screenObserver { NotificationCenter.default.removeObserver(screenObserver) }
    }

    /// Runs while the onboarding gate is showing. A full window scan only
    /// happens on the transition into the granted state.
    func pollAccessibilityState() {
        let wasGranted = accessibilityGranted
        refreshPermissionState()
        if accessibilityGranted {
            if !wasGranted { refresh() }
            return
        }
        // Granted while this process was already running. Its cached answer can
        // never catch up, so hand over to a process that starts out trusted.
        if accessibility.canPerformAccessibilityCalls() {
            AppRelauncher.relaunchOnce()
        }
    }

    /// Restarts the app so a fresh process picks up a permission that was
    /// granted after launch. Exposed for the gate's explicit button.
    func relaunchForAccessibility() {
        AppRelauncher.relaunch()
    }

    /// True when the Accessibility grant cannot outlive a rebuild of this app.
    var permissionResetsOnEveryBuild: Bool { CodeSigningInfo.isAdHocSigned }

    /// Reflows the live group when a display is attached, removed, or resized.
    /// Without this, unplugging a monitor left every member of that group sized
    /// for a screen that no longer exists.
    private func handleScreenParametersChanged() {
        displays = DisplayDescriptor.current()
        screenChangeWorkItem?.cancel()
        let item = DispatchWorkItem { [weak self] in
            guard let self else { return }
            self.screenChangeWorkItem = nil
            self.displays = DisplayDescriptor.current()
            if !self.displays.contains(where: { $0.id == self.selectedDisplayID }) {
                self.selectedDisplayID = self.displayUnderPointer()?.id ?? self.displays.first?.id ?? ""
            }
            guard self.selectedWindows.count >= 2, self.selectedDisplay != nil else { return }
            self.cancelPendingWindowInteraction()
            self.applyCurrentLayout()
        }
        screenChangeWorkItem = item
        // Reconfiguration arrives as a burst and macOS keeps moving windows for a
        // moment afterwards. Reflow once, after it settles.
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.6, execute: item)
    }

    var isTrusted: Bool { accessibilityGranted }
    var canShowWindowPreviews: Bool { accessibility.canCaptureScreen }
    var selectedWindows: [ManagedWindow] {
        windows.filter(\.isSelected).sorted {
            (selectionOrder.firstIndex(of: $0.id) ?? .max) < (selectionOrder.firstIndex(of: $1.id) ?? .max)
        }
    }
    var selectedDisplay: DisplayDescriptor? { displays.first { $0.id == selectedDisplayID } }
    var activeGroup: WindowGroupSnapshot? { groups.first { $0.id == activeGroupID } }

    func group(containing window: ManagedWindow) -> WindowGroupSnapshot? {
        if let exact = groups.first(where: { group in
            group.windows.contains(where: { saved in
                if let savedNumber = saved.windowNumber, let currentNumber = window.windowID {
                    return saved.bundleIdentifier == window.bundleIdentifier
                        && savedNumber == currentNumber
                }
                guard saved.bundleIdentifier == window.bundleIdentifier,
                      saved.title == window.title else { return false }
                // Legacy records lack a WindowServer number. Only infer membership
                // from title when it identifies exactly one current window.
                return windows.filter {
                    $0.bundleIdentifier == saved.bundleIdentifier && $0.title == saved.title
                }.count == 1
            })
        }) { return exact }
        return nil
    }

    /// The capture service. `AccessibilityService` is `Sendable`, so the chooser
    /// can drive thumbnail capture from a background task.
    var previewSource: AccessibilityService { accessibility }

    func previewImage(for windowID: UUID) -> NSImage? {
        guard let window = windows.first(where: { $0.id == windowID }) else { return nil }
        return accessibility.previewImage(for: window)
    }

    func selectedGroupHasFocusedVisibleWindow() -> Bool {
        guard !isActiveGroupMinimized else { return false }
        return activeGroupID != nil && accessibility.focusedWindowBelongs(to: selectedWindows)
    }

    var isActiveGroupMinimized: Bool {
        minimizedGroups.containsActiveGroup(activeGroupID)
    }

    /// Minimizes every window in a group. Clicking its Dock or Command-Tab icon
    /// brings them all back, because restoring a group already un-minimizes its
    /// members before laying them out.
    @discardableResult
    func minimizeGroup(_ id: UUID? = nil) -> Bool {
        let targetID = id ?? activeGroupID
        guard let targetID, groups.contains(where: { $0.id == targetID }) else { return false }
        guard isTrusted else { return false }

        // Resolve members from the saved group so this works even when the
        // group is not the one currently selected.
        guard let group = groups.first(where: { $0.id == targetID }) else { return false }
        refresh(limitedTo: Set(group.windows.map(\.bundleIdentifier)))
        let indexes = resolveWindowIndexes(for: group.windows)
        guard indexes.count >= 2 else { return false }

        let isActiveGroup = activeGroupID == targetID
        if isActiveGroup {
            // Order matters: stop the reconciliation machinery before the
            // selected windows start emitting move and resize notifications.
            invalidateForegroundActivation()
            cancelPendingWindowInteraction()
        }
        minimizedGroups.minimize(targetID)

        for index in indexes {
            accessibility.minimize(windows[index].element)
            windows[index].isMinimized = true
        }
        if isActiveGroup { onLayoutFramesChanged?([]) }
        return true
    }

    @discardableResult
    func requestWindowPreviewPermission() -> Bool {
        accessibility.requestScreenCapturePermission()
    }

    func requestPermission() {
        _ = accessibility.requestPermission(prompt: true)
        accessibilityGranted = accessibility.isTrusted
    }

    func beginAccessibilitySetup() {
        requestPermission()
        openAccessibilitySettings()
    }

    func openAccessibilitySettings() {
        guard let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility") else { return }
        NSWorkspace.shared.open(url)
        // Opening a deep link does not always bring an already-running System
        // Settings window forward. Explicit activation makes the button feel
        // immediate and reliable.
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.35) {
            guard let settings = NSRunningApplication
                .runningApplications(withBundleIdentifier: "com.apple.systempreferences")
                .first else { return }
            WindowActivator.makeFrontmost(pid: settings.processIdentifier, donorPID: nil)
        }
    }

    func refresh() {
        refresh(limitedTo: nil)
    }

    /// Updates the Accessibility permission flag without scanning any windows.
    func refreshPermissionState() {
        accessibilityGranted = accessibility.isTrusted
        if accessibilityGranted { permissionStatusMessage = "" }
    }

    /// - Parameter bundleIDs: when non-nil, only these applications are
    ///   re-scanned and every other known window is carried over untouched.
    ///   A full scan costs several Accessibility round trips per window on the
    ///   system, which is far too slow to sit in front of a Command-Tab.
    private func refresh(limitedTo bundleIDs: Set<String>?) {
        accessibilityGranted = accessibility.isTrusted
        if accessibilityGranted { permissionStatusMessage = "" }
        displays = DisplayDescriptor.current()
        if !displays.contains(where: { $0.id == selectedDisplayID }) {
            selectedDisplayID = displayUnderPointer()?.id ?? displays.first?.id ?? ""
        }
        guard accessibilityGranted else {
            windows = []
            return
        }
        let discovered = accessibility.discoverWindows(previous: windows, limitedTo: bundleIDs)
        if let bundleIDs {
            let untouched = windows.filter { !bundleIDs.contains($0.bundleIdentifier) }
            windows = (untouched + discovered.windows)
                .sorted(by: ManagedWindow.precedesInReadingOrder)
        } else {
            windows = discovered.windows
            unsupportedWindows = discovered.unsupported
        }
        rebuildObservers()
    }

    func toggleSelection(_ id: UUID) {
        guard let index = windows.firstIndex(where: { $0.id == id }) else { return }
        windows[index].isSelected.toggle()
        if windows[index].isSelected {
            if !selectionOrder.contains(id) { selectionOrder.append(id) }
        } else {
            selectionOrder.removeAll { $0 == id }
        }
        ratios = equalRatios(count: selectedWindows.count)
        rebuildObservers()
    }

    func clearSelection() {
        invalidateForegroundActivation()
        cancelPendingWindowInteraction()
        activeGroupID = nil
        for index in windows.indices { windows[index].isSelected = false }
        selectionOrder.removeAll()
        ratios = []
        rebuildObservers()
    }

    func setSelection(inOrder ids: [UUID]) {
        invalidateForegroundActivation()
        cancelPendingWindowInteraction()
        let validIDs = uniquePreservingOrder(ids).filter { id in windows.contains(where: { $0.id == id }) }
        let selectedSet = Set(validIDs)
        for index in windows.indices { windows[index].isSelected = selectedSet.contains(windows[index].id) }
        selectionOrder = validIDs
        ratios = equalRatios(count: validIDs.count)
        rebuildObservers()
    }

    func detachAllWindows() {
        invalidateForegroundActivation()
        let removedGroupID = activeGroupID
        cancelPendingWindowInteraction()
        for index in windows.indices { windows[index].isSelected = false }
        selectionOrder.removeAll()
        ratios.removeAll()
        rebuildObservers()
        if let removedGroupID { removeGroupRecord(removedGroupID) }
    }

    func detachWindow(_ id: UUID, makeMain: Bool = false) {
        invalidateForegroundActivation()
        cancelPendingWindowInteraction()
        let selected = selectedWindows
        guard let removedOffset = selected.firstIndex(where: { $0.id == id }) else { return }
        let detached = selected[removedOffset]

        if ratios.count == selected.count {
            ratios.remove(at: removedOffset)
            let total = ratios.reduce(0, +)
            if total > 0 { ratios = ratios.map { $0 / total } }
        }
        if let index = windows.firstIndex(where: { $0.id == id }) { windows[index].isSelected = false }
        selectionOrder.removeAll { $0 == id }

        if selectedWindows.count >= 2 {
            rebuildObservers()
            applyCurrentLayout()
        } else {
            // A single window is not a connected group; release it as well.
            for index in windows.indices { windows[index].isSelected = false }
            selectionOrder.removeAll()
            ratios.removeAll()
            rebuildObservers()
            if let activeGroupID { removeGroupRecord(activeGroupID) }
        }

        if makeMain {
            AXUIElementPerformAction(detached.element, kAXRaiseAction as CFString)
            NSRunningApplication(processIdentifier: detached.pid)?.activate(options: [.activateIgnoringOtherApps])
        }
    }

    func selectDisplay(containing point: CGPoint) {
        if let display = displays.first(where: { $0.visibleFrame.contains(point) }) {
            selectedDisplayID = display.id
        }
    }

    @discardableResult
    func toggleWindow(at point: CGPoint) -> Bool {
        guard let element = accessibility.window(at: point),
              let index = windows.firstIndex(where: { CFEqual($0.element, element) }) else { return false }
        windows[index].isSelected.toggle()
        let id = windows[index].id
        if windows[index].isSelected {
            if !selectionOrder.contains(id) { selectionOrder.append(id) }
        } else {
            selectionOrder.removeAll { $0 == id }
        }
        ratios = equalRatios(count: selectedWindows.count)
        rebuildObservers()
        return true
    }

    func selectFrontmostWindows(count: Int) {
        // Rank by the WindowServer's own front-to-back order. Ranking by
        // application instead only distinguished "active" from "everything
        // else", and `sorted` is not stable, so the shortcuts used to grab an
        // effectively arbitrary set of windows.
        let order = accessibility.onScreenWindowOrder()
        var depthByWindowNumber: [CGWindowID: Int] = [:]
        for (depth, number) in order.enumerated() where depthByWindowNumber[number] == nil {
            depthByWindowNumber[number] = depth
        }
        let ranked = windows
            .filter { !$0.isMinimized }
            .enumerated()
            .sorted { lhs, rhs in
                let lhsDepth = lhs.element.windowID.flatMap { depthByWindowNumber[$0] } ?? .max
                let rhsDepth = rhs.element.windowID.flatMap { depthByWindowNumber[$0] } ?? .max
                // Keep discovery order as the tie-break so the result is stable.
                return lhsDepth == rhsDepth ? lhs.offset < rhs.offset : lhsDepth < rhsDepth
            }
            .map(\.element)
        let chosen = ranked.prefix(max(2, count)).map(\.id)
        let ids = Set(chosen)
        for index in windows.indices { windows[index].isSelected = ids.contains(windows[index].id) }
        selectionOrder = chosen
        ratios = equalRatios(count: selectedWindows.count)
        rebuildObservers()
    }

    func arrangeEqualColumns(count: Int? = nil) {
        if let count, selectedWindows.count != count { selectFrontmostWindows(count: count) }
        let ids = selectedWindows.map(\.id)
        guard ids.count >= 2 else { lastError = .noWindowsSelected; return }
        if let activeGroupID {
            _ = updateGroup(activeGroupID, inOrder: ids)
        } else {
            _ = createGroup(inOrder: ids)
        }
    }

    /// Whether these windows can be tiled on `display` at all, and which of them
    /// is responsible when they cannot.
    func fitReport(for windows: [ManagedWindow], on display: DisplayDescriptor?) -> (fit: ColumnFit, blocker: ManagedWindow?)? {
        guard windows.count >= 2, let display else { return nil }
        let fit = ColumnLayoutEngine.fit(
            in: display.visibleFrame.width,
            minimumWidths: windows.map { $0.minimumSize.width },
            gap: CGFloat(gap)
        )
        let blocker = fit.fits ? nil : windows.max { $0.minimumSize.width < $1.minimumSize.width }
        return (fit, blocker)
    }

    /// Fit message for a chooser selection, by window id.
    func fitFailureMessage(forSelection ids: [UUID]) -> String? {
        fitFailureMessage(for: ids.compactMap { id in windows.first { $0.id == id } })
    }

    /// The message to show when a selection cannot be tiled.
    func fitFailureMessage(for windows: [ManagedWindow]) -> String? {
        guard let report = fitReport(for: windows, on: selectedDisplay), !report.fit.fits else { return nil }
        let name = report.blocker.map { "\($0.title) — \($0.appName)" } ?? "One of these windows"
        return "\(name) will not go narrow enough. This display is \(Int(report.fit.overflow)) pt short "
            + "for these \(windows.count) windows."
    }

    func applyCurrentLayout() {
        let selected = selectedWindows
        guard isTrusted else { lastError = .permissionRequired; return }
        guard selected.count >= 2 else { lastError = .noWindowsSelected; return }
        guard let display = selectedDisplay else { lastError = .displayUnavailable; return }
        // Check before touching anything. Discovering this mid-apply used to
        // leave some windows moved and others not, with an error on top.
        if let message = fitFailureMessage(for: selected) {
            lastError = .accessibility(message)
            return
        }
        if ratios.count != selected.count { ratios = equalRatios(count: selected.count) }

        do {
            isApplyingLayout = true
            var appliedWidths: [CGFloat] = []
            var effectiveMinimums = selected.map { $0.minimumSize.width }

            // Some applications do not expose AXMinSize. Apply, read back clamped sizes,
            // and recompute up to three times so the connected group still fills the screen.
            for attempt in 0..<3 {
                let targets = try ColumnLayoutEngine.frames(
                    in: display.visibleFrame,
                    ratios: ratios,
                    minimumWidths: effectiveMinimums,
                    gap: CGFloat(gap)
                )
                appliedWidths.removeAll(keepingCapacity: true)
                var discoveredConstraint = false
                for (offset, pair) in zip(selected, targets).enumerated() {
                    let (window, target) = pair
                    let actual: CGRect
                    // A minimized window reports its pre-minimize frame, so a
                    // matching frame is not a reason to skip the write: the write
                    // is what restores it.
                    if framesNearlyEqual(window.frame, target), !window.isMinimized {
                        actual = window.frame
                    } else {
                        suppressFrameEvents(for: window.id, target: target)
                        actual = try accessibility.setFrame(target, of: window.element)
                    }
                    appliedWidths.append(actual.width)
                    if actual.width > target.width + 1 {
                        effectiveMinimums[offset] = max(effectiveMinimums[offset], actual.width)
                        discoveredConstraint = true
                    }
                    if let index = windows.firstIndex(where: { $0.id == window.id }) {
                        windows[index].frame = actual
                        windows[index].minimumSize.width = effectiveMinimums[offset]
                        windows[index].isMinimized = false
                    }
                }
                if !discoveredConstraint || attempt == 2 { break }
                // The application revealed a wider real minimum than it
                // advertised. If that makes the set impossible, stop here rather
                // than letting the engine throw with windows already moved.
                let revised = ColumnLayoutEngine.fit(
                    in: display.visibleFrame.width,
                    minimumWidths: effectiveMinimums,
                    gap: CGFloat(gap)
                )
                if !revised.fits {
                    lastError = .accessibility(
                        "These windows will not fit side by side: they need "
                            + "\(Int(revised.overflow)) pt more than this display has."
                    )
                    break
                }
            }
            // Applications may clamp requested sizes. Use the real widths on the
            // next pass — but only when they actually tile the display, so an
            // overflowing attempt cannot corrupt the stored proportions.
            let total = appliedWidths.reduce(0, +)
            let usable = display.visibleFrame.width - CGFloat(gap) * CGFloat(max(0, appliedWidths.count - 1))
            if total > 0, total <= usable + 1 {
                ratios = appliedWidths.map { $0 / total }
            }
            saveAutomaticWorkspace()
            onLayoutFramesChanged?(selectedWindows.map(\.frame))
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.25) { [weak self] in self?.isApplyingLayout = false }
        } catch ColumnLayoutError.insufficientSpace {
            lastError = .insufficientSpace
            isApplyingLayout = false
        } catch let error as LayoutError {
            lastError = error
            isApplyingLayout = false
        } catch {
            lastError = .accessibility(error.localizedDescription)
            isApplyingLayout = false
        }
    }

    /// The columns a chooser selection would actually produce.
    ///
    /// This runs the real layout engine with the real minimum widths, so the
    /// preview reflects an application that refuses to be narrowed rather than
    /// drawing an idealised set of equal columns.
    ///
    /// - Parameter ids: physical order, left to right.
    func previewLayout(forOrder ids: [UUID]) -> (display: CGRect, frames: [CGRect])? {
        let ordered = ids.compactMap { id in windows.first { $0.id == id } }
        guard ordered.count == ids.count, ordered.count >= 2,
              let display = selectedDisplay else { return nil }
        guard let frames = try? ColumnLayoutEngine.frames(
            in: display.visibleFrame,
            ratios: equalRatios(count: ordered.count),
            minimumWidths: ordered.map { $0.minimumSize.width },
            gap: CGFloat(gap)
        ) else { return nil }
        return (display.visibleFrame, frames)
    }

    func makeSavedLayout(name: String) -> SavedLayout? {
        let selected = selectedWindows
        guard selected.count >= 2, let display = selectedDisplay else { return nil }
        let savedRatios = ratios.count == selected.count ? ratios : equalRatios(count: selected.count)
        return SavedLayout(
            id: UUID(), name: name, displayID: display.id, gap: gap,
            ratios: savedRatios.map(Double.init), windows: selected.map(\.fingerprint)
        )
    }

    @discardableResult
    func createGroup(inOrder ids: [UUID], preferredRatios: [CGFloat]? = nil) -> UUID? {
        guard groups.count < 9 else {
            lastError = .accessibility("Window Columns supports up to nine active groups.")
            return nil
        }
        let validIDs = uniquePreservingOrder(ids).filter { id in windows.contains(where: { $0.id == id }) }
        guard validIDs.count >= 2, let display = selectedDisplay else {
            lastError = .noWindowsSelected
            return nil
        }
        cancelPendingWindowInteraction()

        let selectedSet = Set(validIDs)
        for index in windows.indices { windows[index].isSelected = selectedSet.contains(windows[index].id) }
        selectionOrder = validIDs
        if let preferredRatios, preferredRatios.count == validIDs.count {
            let total = preferredRatios.reduce(0, +)
            ratios = total > 0 ? preferredRatios.map { $0 / total } : equalRatios(count: validIDs.count)
        } else {
            ratios = equalRatios(count: validIDs.count)
        }

        let fingerprints = selectedWindows.map(\.fingerprint)
        removeWindowsFromOtherGroups(fingerprints, except: nil)

        let slot = (0..<9).first { candidate in !groups.contains(where: { $0.slot == candidate }) } ?? groups.count
        let id = UUID()
        let group = WindowGroupSnapshot(
            id: id,
            name: "Group \(slot + 1)",
            slot: slot,
            colorIndex: slot % GroupPalette.count,
            displayID: display.id,
            gap: gap,
            ratios: ratios.map(Double.init),
            windows: uniquePreservingOrder(selectedWindows.map(\.fingerprint)),
            updatedAt: Date()
        )
        groups.append(group)
        groups.sort { $0.slot < $1.slot }
        activeGroupID = id
        persistGroups()
        rebuildObservers()
        captureArrangementUndo(createdGroupID: id, groupName: group.name)
        applyCurrentLayout()
        return id
    }

    @discardableResult
    func updateGroup(_ id: UUID, inOrder ids: [UUID]) -> Bool {
        let validIDs = uniquePreservingOrder(ids).filter { candidate in
            windows.contains(where: { $0.id == candidate })
        }
        guard validIDs.count >= 2,
              groups.contains(where: { $0.id == id }),
              let display = selectedDisplay else { return false }
        cancelPendingWindowInteraction()

        let selectedSet = Set(validIDs)
        for index in windows.indices { windows[index].isSelected = selectedSet.contains(windows[index].id) }
        selectionOrder = validIDs
        ratios = equalRatios(count: validIDs.count)
        let fingerprints = selectedWindows.map(\.fingerprint)
        removeWindowsFromOtherGroups(fingerprints, except: id)

        guard let refreshedIndex = groups.firstIndex(where: { $0.id == id }) else { return false }
        groups[refreshedIndex].displayID = display.id
        groups[refreshedIndex].windows = uniquePreservingOrder(selectedWindows.map(\.fingerprint))
        groups[refreshedIndex].ratios = ratios.map(Double.init)
        groups[refreshedIndex].gap = gap
        groups[refreshedIndex].updatedAt = Date()
        activeGroupID = groups[refreshedIndex].id
        persistGroups()
        rebuildObservers()
        captureArrangementUndo(createdGroupID: nil, groupName: groups[refreshedIndex].name)
        applyCurrentLayout()
        return true
    }

    @discardableResult
    func moveWindow(_ windowID: UUID, toGroup groupID: UUID) -> Bool {
        guard let window = windows.first(where: { $0.id == windowID }),
              groups.contains(where: { $0.id == groupID }) else { return false }
        let fingerprint = window.fingerprint
        let movedFromActiveGroup = activeGroup?.windows.contains(where: { $0.matches(fingerprint) }) == true

        for index in groups.indices where groups[index].id != groupID {
            groups[index].windows.removeAll { $0.matches(fingerprint) }
            if groups[index].ratios.count != groups[index].windows.count, !groups[index].windows.isEmpty {
                groups[index].ratios = Array(
                    repeating: 1 / Double(groups[index].windows.count),
                    count: groups[index].windows.count
                )
            }
        }
        groups.removeAll { $0.id != groupID && $0.windows.count < 2 }
        if let activeGroupID, !groups.contains(where: { $0.id == activeGroupID }) {
            self.activeGroupID = nil
        }

        guard let targetIndex = groups.firstIndex(where: { $0.id == groupID }) else { return false }
        if !groups[targetIndex].windows.contains(where: { $0.matches(fingerprint) }) {
            groups[targetIndex].windows.append(fingerprint)
        }
        groups[targetIndex].ratios = Array(
            repeating: 1 / Double(groups[targetIndex].windows.count),
            count: groups[targetIndex].windows.count
        )
        groups[targetIndex].updatedAt = Date()
        persistGroups()
        if movedFromActiveGroup {
            activeGroupID = nil
            clearSelection()
        }
        return true
    }

    @discardableResult
    func activateGroup(_ id: UUID, activationDonorPID: pid_t? = nil) -> Bool {
        guard let group = groups.first(where: { $0.id == id }) else { return false }
        // Only the group's own applications need re-scanning to restore it.
        refresh(limitedTo: Set(group.windows.map(\.bundleIdentifier)))
        guard let refreshed = groups.first(where: { $0.id == id }) else { return false }
        // Deliberately no full rescan afterwards. Windows outside this group are
        // left slightly stale, and every reader of the full list already
        // refreshes before using it: the chooser rescans in `reload`, the
        // shortcuts rescan before arranging, and Settings rescans on appear.
        // Sweeping every window on the system 0.4s after each activation cost
        // more than the rest of the activation put together.
        return restoreGroup(refreshed, activationDonorPID: activationDonorPID)
    }

    /// An arrangement is undoable for two minutes. Past that the user has moved
    /// on and restoring old frames would be a surprise, not a rescue.
    var undoableArrangementName: String? {
        guard let arrangementUndo,
              Date().timeIntervalSince(arrangementUndo.capturedAt) < 120 else { return nil }
        return arrangementUndo.groupName
    }

    /// Records where the windows are before an arrangement moves them.
    private func captureArrangementUndo(createdGroupID: UUID?, groupName: String) {
        let entries = selectedWindows.map {
            ArrangementUndo.Entry(windowID: $0.id, element: $0.element, frame: $0.frame)
        }
        guard entries.count >= 2 else { return }
        arrangementUndo = ArrangementUndo(
            entries: entries,
            createdGroupID: createdGroupID,
            groupName: groupName,
            capturedAt: Date()
        )
    }

    /// Puts the windows back where they were before the last arrangement.
    func undoLastArrangement() {
        guard undoableArrangementName != nil, let undo = arrangementUndo, isTrusted else { return }
        arrangementUndo = nil
        invalidateForegroundActivation()
        cancelPendingWindowInteraction()

        // Dismantle first. While the group is still active the pointer-release
        // check would see the restored frames as displacement and re-tile them.
        if let createdGroupID = undo.createdGroupID { removeGroupRecord(createdGroupID) }
        activeGroupID = nil
        for index in windows.indices { windows[index].isSelected = false }
        selectionOrder.removeAll()
        ratios.removeAll()
        rebuildObservers()

        for entry in undo.entries {
            suppressFrameEvents(for: entry.windowID, target: entry.frame, duration: 0.4)
            guard let restored = try? accessibility.setFrame(entry.frame, of: entry.element) else { continue }
            if let index = windows.firstIndex(where: { $0.id == entry.windowID }) {
                windows[index].frame = restored
            }
        }
    }

    /// Renames a group. An empty name restores the default "Group N".
    func renameGroup(_ id: UUID, to proposed: String) {
        guard let index = groups.firstIndex(where: { $0.id == id }) else { return }
        let trimmed = proposed.trimmingCharacters(in: .whitespacesAndNewlines)
        let custom = trimmed.isEmpty ? nil : String(trimmed.prefix(40))
        guard groups[index].customName != custom else { return }
        groups[index].customName = custom
        groups[index].name = custom ?? "Group \(groups[index].slot + 1)"
        groups[index].updatedAt = Date()
        persistGroups()
        onGroupRenamed?(groups[index])
    }

    func deleteGroup(_ id: UUID) {
        let isActive = activeGroupID == id
        removeGroupRecord(id)
        if isActive {
            clearSelection()
        }
    }

    func applySavedLayout(_ layout: SavedLayout) {
        if displays.contains(where: { $0.id == layout.displayID }) { selectedDisplayID = layout.displayID }
        let chosenIDs = resolveWindowIndexes(for: layout.windows).map { windows[$0].id }
        guard chosenIDs.count >= 2 else {
            lastError = .noWindowsSelected
            return
        }
        activeGroupID = nil
        gap = layout.gap
        _ = createGroup(
            inOrder: chosenIDs,
            preferredRatios: layout.ratios.map { CGFloat($0) }
        )
    }

    private func restoreGroup(_ group: WindowGroupSnapshot, activationDonorPID: pid_t? = nil) -> Bool {
        guard isTrusted else { return false }
        if displays.contains(where: { $0.id == group.displayID }) { selectedDisplayID = group.displayID }
        let chosen = resolveWindowIndexes(for: group.windows)
        guard chosen.count >= 2 else { return false }

        // Whatever happens next is a restore, so this group is no longer being
        // held minimized on purpose. Other minimized groups remain independent.
        minimizedGroups.restore(group.id)

        // Minimized windows cannot be raised or resized. Restore them before the
        // layout pass, then re-read their real frames.
        let minimized = chosen.filter { windows[$0].isMinimized }
        for index in minimized {
            accessibility.unminimize(windows[index].element)
            windows[index].isMinimized = false
        }
        if !minimized.isEmpty {
            for index in minimized {
                if let frame = accessibility.currentFrame(of: windows[index].element) {
                    windows[index].frame = frame
                }
            }
        }

        activeGroupID = group.id
        setSelection(inOrder: chosen.map { windows[$0].id })
        gap = min(max(group.gap, 0), 64)
        ratios = group.ratios.count == chosen.count ? group.ratios.map { CGFloat($0) } : equalRatios(count: chosen.count)
        applyCurrentLayout()
        bringManagedGroupToFront(activationDonorPID: activationDonorPID)
        return true
    }

    private func bringManagedGroupToFront(activationDonorPID: pid_t? = nil) {
        let group = selectedWindows
        guard group.count >= 2, let groupID = activeGroupID else { return }

        foregroundActivationGeneration &+= 1
        let generation = foregroundActivationGeneration
        raiseManagedGroup(
            group,
            groupID: groupID,
            generation: generation,
            activateOwner: true,
            donorPID: activationDonorPID
        )

        // A Command-Tab activation arrives while macOS is still transferring focus
        // away from the lightweight group host. Repeat the exact-window raise after
        // that transfer settles so every member appears on the first Command-Tab.
        for (delay, activateOwner) in [(0.06, true), (0.18, false)] {
            DispatchQueue.main.asyncAfter(deadline: .now() + delay) { [weak self] in
                guard let self,
                      self.foregroundActivationGeneration == generation,
                      self.activeGroupID == groupID else { return }
                self.raiseManagedGroup(
                    self.selectedWindows,
                    groupID: groupID,
                    generation: generation,
                    activateOwner: activateOwner,
                    donorPID: activationDonorPID
                )
            }
        }
    }

    private func raiseManagedGroup(
        _ group: [ManagedWindow],
        groupID: UUID,
        generation: Int,
        activateOwner: Bool,
        donorPID: pid_t?
    ) {
        guard foregroundActivationGeneration == generation,
              activeGroupID == groupID,
              group.count >= 2,
              let main = group.last else { return }

        // Activate only the main owner. Activating every owner in sequence makes
        // multi-app groups flicker and can expose unrelated windows from those apps.
        // Activation raises all of that application's windows, so it has to happen
        // before the members owned by the other applications are raised.
        if activateOwner {
            WindowActivator.makeFrontmost(pid: main.pid, donorPID: donorPID)
        }
        for window in group {
            WindowActivator.raise(window.element)
        }

        // Number 1 is the rightmost card, stored as the last physical column.
        WindowActivator.raise(main.element)
        WindowActivator.focus(main.element)
    }

    private func invalidateForegroundActivation() {
        foregroundActivationGeneration &+= 1
    }

    private func handleAccessibilityEvent(element: AXUIElement, notification: String) {
        if notification == kAXFocusedWindowChangedNotification as String {
            onFrontmostWindowChanged?()
            return
        }
        if notification == kAXUIElementDestroyedNotification as String {
            if let destroyed = windows.first(where: { CFEqual($0.element, element) }) {
                removeClosedWindowFromGroups(destroyed.fingerprint)
            }
            refresh()
            return
        }
        guard let window = selectedWindows.first(where: { CFEqual($0.element, element) }) else { return }
        // A deliberately minimized group emits move and resize notifications as
        // it goes down; reconciling them would immediately restore it.
        if isActiveGroupMinimized { return }
        // Divider writes generate the same AX notifications as user resizing.
        // Never feed those notifications back into the layout engine.
        if dividerDragSession != nil || dividerWriteInFlight || pendingDividerWrites != nil { return }
        if let suppression = suppressedFrameEvents[window.id], suppression.expires > Date() {
            if let current = accessibility.currentFrame(of: element),
               framesNearlyEqual(current, suppression.target) {
                return
            }
            // A real user movement supersedes our old write immediately.
            suppressedFrameEvents.removeValue(forKey: window.id)
        }
        suppressedFrameEvents = suppressedFrameEvents.filter { $0.value.expires > Date() }
        let moved = notification == kAXWindowMovedNotification as String
        let resized = notification == kAXWindowResizedNotification as String
        if var pending = pendingFrameEvents[window.id] {
            pending.wasMoved = pending.wasMoved || moved
            pending.wasResized = pending.wasResized || resized
            pendingFrameEvents[window.id] = pending
        } else {
            pendingFrameEvents[window.id] = PendingFrameEvent(
                element: element,
                wasMoved: moved,
                wasResized: resized
            )
        }
        guard pendingResize == nil else { return }

        let item = DispatchWorkItem { [weak self] in
            guard let self else { return }
            self.pendingResize = nil
            let events = self.pendingFrameEvents
            self.pendingFrameEvents.removeAll(keepingCapacity: true)
            for (id, event) in events {
                self.processInteractiveChange(windowID: id, event: event)
            }
        }
        pendingResize = item
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.016, execute: item)
    }

    private func processInteractiveChange(windowID: UUID, event: PendingFrameEvent) {
        let selected = selectedWindows
        guard let changedIndex = selected.firstIndex(where: { $0.id == windowID }),
              let newFrame = accessibility.currentFrame(of: event.element) else { return }
        let oldFrame = selected[changedIndex].frame
        let leftDelta = newFrame.minX - oldFrame.minX
        let rightDelta = newFrame.maxX - oldFrame.maxX
        let widthDelta = newFrame.width - oldFrame.width
        let heightDelta = newFrame.height - oldFrame.height
        let verticalDelta = newFrame.minY - oldFrame.minY
        let threshold: CGFloat = 1

        // A move notification with a stable size is a window drag. Do not rely
        // on a title-bar hit test: custom title bars, tabs, and toolbar styles
        // make that test unreliable. Even a small or vertical move must snap.
        let positionChanged = max(abs(leftDelta), abs(verticalDelta)) >= 0.5
        if event.wasMoved,
           abs(widthDelta) <= 2,
           abs(heightDelta) <= 2,
           positionChanged {
            let slotFrames: [CGRect]
            if let display = selectedDisplay,
               let targets = try? ColumnLayoutEngine.frames(
                    in: display.visibleFrame,
                    ratios: ratios.count == selected.count ? ratios : equalRatios(count: selected.count),
                    minimumWidths: selected.map { $0.minimumSize.width },
                    gap: CGFloat(gap)
               ) {
                slotFrames = targets
            } else {
                slotFrames = selected.map(\.frame)
            }
            let targetIndex = ColumnLayoutEngine.nearestColumnIndex(
                to: newFrame.midX,
                in: slotFrames
            ) ?? changedIndex
            pendingSwap = (windowID, targetIndex)
            // Cache the real moved frame so the final layout pass sees that the
            // window differs from its target and actually writes the snap-back.
            if let index = windows.firstIndex(where: { $0.id == windowID }) {
                windows[index].frame = newFrame
            }
            markInteractionForReconciliation()
            return
        }

        let somethingChanged = abs(widthDelta) > threshold
            || abs(heightDelta) > threshold
            || positionChanged
        guard somethingChanged else { return }

        let widths = selected.map { $0.frame.width }
        let minimums = selected.map { $0.minimumSize.width }
        var divider: Int?
        var delta: CGFloat = 0
        if abs(leftDelta) > threshold, abs(rightDelta) <= threshold, changedIndex > 0 {
            divider = changedIndex - 1
            delta = leftDelta
        } else if abs(rightDelta) > threshold, abs(leftDelta) <= threshold, changedIndex < selected.count - 1 {
            divider = changedIndex
            delta = rightDelta
        } else if abs(widthDelta) > threshold {
            divider = abs(leftDelta) > abs(rightDelta) ? changedIndex - 1 : changedIndex
            delta = divider == changedIndex - 1 ? leftDelta : rightDelta
        }

        if let index = windows.firstIndex(where: { $0.id == windowID }) { windows[index].frame = newFrame }
        guard let divider, divider >= 0, divider < selected.count - 1 else {
            // Not expressible as a divider move: the outer edge of an end
            // column, a corner drag, or a height change. This used to return
            // silently and leave the window stranded outside the group — for a
            // pair, that is every drag of the rightmost window's right edge. A
            // group is a set of full-height columns spanning the display, so
            // reconcile instead of abandoning it.
            markInteractionForReconciliation()
            return
        }
        ratios = ColumnLayoutEngine.adjustedRatios(
            movingDividerAfter: divider,
            by: delta,
            currentWidths: widths,
            minimumWidths: minimums
        )
        markInteractionForReconciliation()
        // Do not fight a native edge drag by moving its neighbor while the mouse
        // is still down. The white divider provides live grouped resizing; a
        // normal window-edge drag is reconciled once, on mouse-up.
    }

    private func rebuildObservers() {
        accessibility.observe(selectedWindows) { [weak self] element, notification in
            self?.handleAccessibilityEvent(element: element, notification: notification)
        }
        updateMouseUpMonitor()
        onLayoutStateChanged?(selectedWindows.count >= 2)
        onLayoutFramesChanged?(selectedWindows.count >= 2 ? selectedWindows.map(\.frame) : [])
    }

    private func updateMouseUpMonitor() {
        if selectedWindows.count >= 2, mouseUpMonitor == nil {
            mouseDownMonitor = NSEvent.addGlobalMonitorForEvents(matching: .leftMouseDown) { [weak self] _ in
                let location = NSEvent.mouseLocation
                Task { @MainActor in self?.pointerDownLocation = location }
            }
            mouseUpMonitor = NSEvent.addGlobalMonitorForEvents(matching: .leftMouseUp) { [weak self] _ in
                let location = NSEvent.mouseLocation
                Task { @MainActor in
                    guard let self else { return }
                    let start = self.pointerDownLocation
                    self.pointerDownLocation = nil
                    self.finishInteractiveResize()
                    // A click that never moved cannot have displaced a window,
                    // so it costs nothing.
                    guard let start,
                          hypot(location.x - start.x, location.y - start.y) > 3 else { return }
                    self.scheduleGroupVerification()
                }
            }
        } else if selectedWindows.count < 2, let mouseUpMonitor {
            NSEvent.removeMonitor(mouseUpMonitor)
            self.mouseUpMonitor = nil
            if let mouseDownMonitor { NSEvent.removeMonitor(mouseDownMonitor) }
            self.mouseDownMonitor = nil
            pointerDownLocation = nil
            groupVerificationWorkItem?.cancel()
            groupVerificationWorkItem = nil
        }
    }

    private func scheduleGroupVerification() {
        guard !isActiveGroupMinimized else { return }
        groupVerificationWorkItem?.cancel()
        let item = DispatchWorkItem { [weak self] in
            guard let self else { return }
            self.groupVerificationWorkItem = nil
            self.verifyGroupAgainstLayout()
        }
        groupVerificationWorkItem = item
        // After the event-driven pass at +0.04s, so this only has work to do
        // when that pass never happened.
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.09, execute: item)
    }

    /// Confirms every grouped window is still in its column once the pointer is
    /// released, and puts back any that is not.
    ///
    /// The event-driven path only runs when the dragged application emits
    /// `kAXWindowMovedNotification`, and many applications — Chromium and
    /// Electron windows, anything with a custom title bar — emit those
    /// unreliably or not at all during a drag. A window dropped by one of those
    /// simply stayed where it landed. Reading the real frames once per release
    /// makes snapping back independent of any notification. It performs no
    /// Accessibility writes when nothing actually moved.
    private func verifyGroupAgainstLayout() {
        guard !isActiveGroupMinimized else { return }
        guard dividerDragSession == nil, !dividerWriteInFlight, pendingDividerWrites == nil else { return }
        // A pending event-driven reconciliation already owns this gesture, and a
        // layout pass that is still writing frames would otherwise be misread as
        // displacement and applied a second time.
        guard !interactionNeedsReconciliation, !isApplyingLayout else { return }
        let selected = selectedWindows
        guard selected.count >= 2, let display = selectedDisplay else { return }
        if ratios.count != selected.count { ratios = equalRatios(count: selected.count) }
        guard let targets = try? ColumnLayoutEngine.frames(
            in: display.visibleFrame,
            ratios: ratios,
            minimumWidths: selected.map { $0.minimumSize.width },
            gap: CGFloat(gap)
        ) else { return }

        var moved: (offset: Int, frame: CGRect)?
        var sawResize = false
        var actualWidths: [CGFloat] = []
        for (offset, window) in selected.enumerated() {
            guard let frame = accessibility.currentFrame(of: window.element) else {
                actualWidths.append(window.frame.width)
                continue
            }
            if let index = windows.firstIndex(where: { $0.id == window.id }) {
                windows[index].frame = frame
            }
            actualWidths.append(frame.width)
            switch ColumnDisplacement(actual: frame, target: targets[offset]) {
            case .inPlace: break
            case .moved: moved = (offset, frame)
            case .resized: sawResize = true
            }
        }
        guard moved != nil || sawResize else { return }

        if sawResize {
            // An inner edge drag redistributes width between neighbours, so the
            // columns still add up to the usable width; adopt those widths and
            // the user keeps their resize. Anything else — an outer edge, a
            // corner, a height change — no longer forms a connected group, so
            // the previous proportions are restored instead.
            let available = display.visibleFrame.width - CGFloat(gap) * CGFloat(selected.count - 1)
            let total = actualWidths.reduce(0, +)
            if total > 0, abs(total - available) <= 2 {
                ratios = actualWidths.map { $0 / total }
            }
        }

        // Crossing a column centre reorders the group; anything else snaps home.
        if let moved {
            let destination = ColumnLayoutEngine.nearestColumnIndex(to: moved.frame.midX, in: targets) ?? moved.offset
            if destination != moved.offset,
               let currentIndex = selectionOrder.firstIndex(of: selected[moved.offset].id) {
                let id = selectionOrder.remove(at: currentIndex)
                selectionOrder.insert(id, at: min(max(destination, 0), selectionOrder.count))
                if ratios.indices.contains(currentIndex) {
                    let ratio = ratios.remove(at: currentIndex)
                    ratios.insert(ratio, at: min(destination, ratios.count))
                }
            }
        }
        applyCurrentLayout()
    }

    private func finishInteractiveResize() {
        guard interactionNeedsReconciliation else { return }
        interactionFinishWorkItem?.cancel()
        interactionFinishWorkItem = nil
        interactionNeedsReconciliation = false
        if let pendingSwap {
            self.pendingSwap = nil
            if let currentIndex = selectionOrder.firstIndex(of: pendingSwap.windowID) {
                let id = selectionOrder.remove(at: currentIndex)
                let destination = min(max(pendingSwap.targetIndex, 0), selectionOrder.count)
                selectionOrder.insert(id, at: destination)
                if ratios.indices.contains(currentIndex) {
                    let ratio = ratios.remove(at: currentIndex)
                    ratios.insert(ratio, at: min(destination, ratios.count))
                }
            }
        }
        layoutReconciliationWorkItem?.cancel()
        let item = DispatchWorkItem { [weak self] in
            guard let self, self.selectedWindows.count >= 2 else { return }
            self.applyCurrentLayout()
        }
        layoutReconciliationWorkItem = item
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.04, execute: item)
    }

    private func scheduleInteractionFinishFallback() {
        interactionFinishWorkItem?.cancel()
        let item = DispatchWorkItem { [weak self] in
            guard let self else { return }
            if NSEvent.pressedMouseButtons & 1 != 0 {
                self.scheduleInteractionFinishFallback()
            } else {
                self.finishInteractiveResize()
            }
        }
        interactionFinishWorkItem = item
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.18, execute: item)
    }

    private func markInteractionForReconciliation() {
        interactionNeedsReconciliation = true
        if NSEvent.pressedMouseButtons & 1 == 0 {
            finishInteractiveResize()
        } else {
            scheduleInteractionFinishFallback()
        }
    }

    private func cancelPendingWindowInteraction() {
        pendingResize?.cancel()
        pendingResize = nil
        pendingFrameEvents.removeAll()
        pendingSwap = nil
        interactionNeedsReconciliation = false
        interactionFinishWorkItem?.cancel()
        interactionFinishWorkItem = nil
        layoutReconciliationWorkItem?.cancel()
        layoutReconciliationWorkItem = nil
        groupVerificationWorkItem?.cancel()
        groupVerificationWorkItem = nil
        pointerDownLocation = nil
    }

    private func saveAutomaticWorkspace() {
        updateActiveGroupSnapshot()
    }

    private func updateActiveGroupSnapshot() {
        guard let activeGroupID,
              let index = groups.firstIndex(where: { $0.id == activeGroupID }),
              let display = selectedDisplay,
              selectedWindows.count >= 2,
              ratios.count == selectedWindows.count else { return }
        groups[index].displayID = display.id
        groups[index].gap = gap
        groups[index].ratios = ratios.map(Double.init)
        groups[index].windows = uniquePreservingOrder(selectedWindows.map(\.fingerprint))
        groups[index].updatedAt = Date()
        persistGroups()
    }

    private func removeWindowsFromOtherGroups(
        _ fingerprints: [WindowFingerprint],
        except excludedGroupID: UUID?
    ) {
        groups = groups.compactMap { group in
            if group.id == excludedGroupID { return group }
            var updated = group
            updated.windows.removeAll { saved in
                fingerprints.contains(where: { $0.matches(saved) })
            }
            guard updated.windows.count >= 2 else { return nil }
            if updated.ratios.count != updated.windows.count {
                updated.ratios = Array(repeating: 1 / Double(updated.windows.count), count: updated.windows.count)
            }
            return updated
        }
        if let activeGroupID, !groups.contains(where: { $0.id == activeGroupID }) {
            self.activeGroupID = nil
        }
        persistGroups()
    }

    private func removeGroupRecord(_ id: UUID) {
        minimizedGroups.restore(id)
        groups.removeAll { $0.id == id }
        if activeGroupID == id { activeGroupID = nil }
        persistGroups()
    }

    private func persistGroups() {
        compactGroupSlots()
        minimizedGroups.retain(only: groups.map(\.id))
        if let data = try? JSONEncoder().encode(groups) {
            UserDefaults.standard.set(data, forKey: groupsKey)
        }
        onGroupsChanged?(groups)
        onLayoutStateChanged?(!groups.isEmpty)
    }

    func dragDivider(after divider: Int, by delta: CGFloat) {
        let selected = selectedWindows
        guard divider >= 0, divider < selected.count - 1 else { return }
        if dividerDragSession?.divider != divider
            || dividerDragSession?.widths.count != selected.count {
            dividerDragSession = (
                divider: divider,
                widths: selected.map { $0.frame.width },
                totalDelta: 0
            )
        }
        dividerDragSession?.totalDelta += delta
        guard let session = dividerDragSession else { return }
        ratios = ColumnLayoutEngine.adjustedRatios(
            movingDividerAfter: divider,
            by: session.totalDelta,
            currentWidths: session.widths,
            minimumWidths: selected.map { $0.minimumSize.width }
        )
        scheduleDividerLayout(after: divider)
    }

    func finishDividerDrag(completion: @escaping () -> Void) {
        dividerFinishCompletion = completion
        finishDividerWhenWritesComplete = true
        if !dividerWriteInFlight, pendingDividerWrites == nil {
            completeDividerDrag()
        }
    }

    private func scheduleDividerLayout(after divider: Int) {
        let selected = selectedWindows
        guard let display = selectedDisplay,
              divider >= 0, divider + 1 < selected.count,
              ratios.count == selected.count else { return }
        do {
            let targets = try ColumnLayoutEngine.frames(
                in: display.visibleFrame,
                ratios: ratios,
                minimumWidths: selected.map { $0.minimumSize.width },
                gap: CGFloat(gap)
            )
            let writes = [divider, divider + 1].compactMap { offset -> DividerFrameWrite? in
                let window = selected[offset]
                guard !framesNearlyEqual(window.frame, targets[offset]) else { return nil }
                suppressFrameEvents(for: window.id, target: targets[offset], duration: 0.5)
                return DividerFrameWrite(windowID: window.id, element: window.element, target: targets[offset])
            }
            guard !writes.isEmpty else { return }
            // Replace queued work with the newest absolute targets. Accessibility
            // can be slower than mouse events; replaying stale intermediate frames
            // is the main source of delayed, jumpy resizing.
            pendingDividerWrites = writes
            startNextDividerWriteIfNeeded()
        } catch ColumnLayoutError.insufficientSpace {
            lastError = .insufficientSpace
        } catch {
            lastError = .accessibility(error.localizedDescription)
        }
    }

    private func startNextDividerWriteIfNeeded() {
        guard !dividerWriteInFlight, let writes = pendingDividerWrites else {
            if finishDividerWhenWritesComplete, !dividerWriteInFlight, pendingDividerWrites == nil {
                completeDividerDrag()
            }
            return
        }
        pendingDividerWrites = nil
        dividerWriteInFlight = true
        let frameService = accessibility
        dividerWriteQueue.async { [weak self] in
            var results: [(UUID, CGRect)] = []
            var failure: String?
            for write in writes {
                do {
                    results.append((write.windowID, try frameService.setFrame(write.target, of: write.element)))
                } catch {
                    failure = error.localizedDescription
                    break
                }
            }
            DispatchQueue.main.async {
                self?.didCompleteDividerWrite(results: results, failure: failure)
            }
        }
    }

    private func didCompleteDividerWrite(results: [(UUID, CGRect)], failure: String?) {
        for (id, frame) in results {
            if let index = windows.firstIndex(where: { $0.id == id }) {
                windows[index].frame = frame
                windows[index].isMinimized = false
            }
        }
        if let failure { lastError = .accessibility(failure) }
        dividerWriteInFlight = false
        onLayoutFramesChanged?(selectedWindows.map(\.frame))
        startNextDividerWriteIfNeeded()
    }

    private func completeDividerDrag() {
        finishDividerWhenWritesComplete = false
        dividerDragSession = nil
        let widths = selectedWindows.map(\.frame.width)
        let total = widths.reduce(0, +)
        if total > 0, widths.count == ratios.count {
            ratios = widths.map { $0 / total }
        }
        saveAutomaticWorkspace()
        onLayoutFramesChanged?(selectedWindows.map(\.frame))
        let completion = dividerFinishCompletion
        dividerFinishCompletion = nil
        completion?()
    }

    private func compactGroupSlots() {
        groups.sort { lhs, rhs in
            lhs.slot == rhs.slot ? lhs.updatedAt < rhs.updatedAt : lhs.slot < rhs.slot
        }
        for index in groups.indices {
            groups[index].slot = index
            groups[index].colorIndex = index % GroupPalette.count
            // Only the default name tracks the slot. This used to overwrite the
            // name unconditionally on every save, which made a group impossible
            // to name even though the model, the chooser, and the companion's
            // Dock badge all display it.
            groups[index].name = groups[index].customName ?? "Group \(index + 1)"
        }
    }

    private func framesNearlyEqual(_ lhs: CGRect, _ rhs: CGRect) -> Bool {
        abs(lhs.minX - rhs.minX) < 1
            && abs(lhs.minY - rhs.minY) < 1
            && abs(lhs.width - rhs.width) < 1
            && abs(lhs.height - rhs.height) < 1
    }

    private func suppressFrameEvents(
        for windowID: UUID,
        target: CGRect,
        duration: TimeInterval = 0.12
    ) {
        suppressedFrameEvents[windowID] = SuppressedFrameEvent(
            expires: Date().addingTimeInterval(duration),
            target: target
        )
    }

    /// Maps saved fingerprints onto live windows, in the saved order.
    /// See `WindowMatcher` for the matching rules.
    private func resolveWindowIndexes(for fingerprints: [WindowFingerprint]) -> [Int] {
        WindowMatcher.resolve(
            saved: fingerprints.map {
                WindowIdentity(
                    bundleIdentifier: $0.bundleIdentifier,
                    title: $0.title,
                    windowNumber: $0.windowNumber
                )
            },
            available: windows.map {
                WindowIdentity(
                    bundleIdentifier: $0.bundleIdentifier,
                    title: $0.title,
                    windowNumber: $0.windowID
                )
            }
        )
    }

    private func removeClosedWindowFromGroups(_ fingerprint: WindowFingerprint) {
        let previouslyActiveGroupID = activeGroupID
        groups = groups.compactMap { group in
            var updated = group
            updated.windows.removeAll { $0.matches(fingerprint) }
            guard updated.windows.count >= 2 else { return nil }
            if updated.ratios.count != updated.windows.count {
                updated.ratios = Array(
                    repeating: 1 / Double(updated.windows.count),
                    count: updated.windows.count
                )
            }
            return updated
        }
        if let activeGroupID, !groups.contains(where: { $0.id == activeGroupID }) {
            self.activeGroupID = nil
        }
        if let previouslyActiveGroupID,
           !groups.contains(where: { $0.id == previouslyActiveGroupID }) {
            cancelPendingWindowInteraction()
            for index in windows.indices { windows[index].isSelected = false }
            selectionOrder.removeAll()
            ratios.removeAll()
        }
        persistGroups()
    }

    private func displayUnderPointer() -> DisplayDescriptor? {
        let point = NSEvent.mouseLocation
        return displays.first { $0.visibleFrame.contains(point) }
    }

    private func equalRatios(count: Int) -> [CGFloat] {
        guard count > 0 else { return [] }
        return Array(repeating: 1 / CGFloat(count), count: count)
    }
}

private func uniquePreservingOrder<Element: Hashable>(_ values: [Element]) -> [Element] {
    var seen: Set<Element> = []
    return values.filter { seen.insert($0).inserted }
}
