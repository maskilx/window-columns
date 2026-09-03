import AppKit
@preconcurrency import ApplicationServices
import Foundation

// AX frame operations are safe to issue from the dedicated serial resize queue.
// Observer registration and discovery remain confined to the main actor.
final class AccessibilityService: @unchecked Sendable {
    private struct WindowDescriptor {
        let id: CGWindowID
        let pid: pid_t
        let title: String
        let frame: CGRect
    }

    fileprivate final class ObserverContext {
        let handler: (AXUIElement, String) -> Void
        init(handler: @escaping (AXUIElement, String) -> Void) { self.handler = handler }
    }

    private struct ObserverRecord {
        let observer: AXObserver
        let context: ObserverContext
    }

    private var observers: [pid_t: ObserverRecord] = [:]

    var isTrusted: Bool { AXIsProcessTrusted() }
    var canCaptureScreen: Bool { CGPreflightScreenCaptureAccess() }

    @discardableResult
    func requestScreenCapturePermission() -> Bool {
        CGRequestScreenCaptureAccess()
    }

    @discardableResult
    func requestPermission(prompt: Bool) -> Bool {
        let options = [kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String: prompt] as CFDictionary
        return AXIsProcessTrustedWithOptions(options)
    }

    /// - Parameter bundleIDs: when non-nil, only these applications are scanned.
    ///   Restoring a group needs a handful of applications, not every window on
    ///   the system, and each window costs several Accessibility round trips.
    func discoverWindows(
        previous: [ManagedWindow] = [],
        limitedTo bundleIDs: Set<String>? = nil
    ) -> (windows: [ManagedWindow], unsupported: [String]) {
        guard isTrusted else { return ([], []) }
        var result: [ManagedWindow] = []
        var unsupported: [String] = []
        var reusedIDs: Set<UUID> = []
        var seenElements: [AXUIElement] = []
        let windowDescriptors = currentWindowDescriptors()

        for app in NSWorkspace.shared.runningApplications where app.activationPolicy == .regular && app.processIdentifier != ProcessInfo.processInfo.processIdentifier {
            if let bundleIDs,
               !bundleIDs.contains(app.bundleIdentifier ?? "pid.\(app.processIdentifier)") {
                continue
            }
            let appElement = AXUIElementCreateApplication(app.processIdentifier)
            guard let elements: [AXUIElement] = copyAttribute(kAXWindowsAttribute as CFString, from: appElement) else { continue }

            for element in elements {
                guard !seenElements.contains(where: { CFEqual($0, element) }) else { continue }
                seenElements.append(element)
                let title: String = copyAttribute(kAXTitleAttribute as CFString, from: element) ?? "Untitled Window"
                let minimized: Bool = copyAttribute(kAXMinimizedAttribute as CFString, from: element) ?? false
                let fullScreen = isFullScreen(element)

                guard (isSettable(kAXPositionAttribute as CFString, on: element) && isSettable(kAXSizeAttribute as CFString, on: element)) || fullScreen,
                      let frame = frame(of: element) else {
                    unsupported.append("\(app.localizedName ?? "Application") — \(title)")
                    continue
                }

                let bundleID = app.bundleIdentifier ?? "pid.\(app.processIdentifier)"
                let old = previous.first { !reusedIDs.contains($0.id) && CFEqual($0.element, element) }
                    ?? previous
                        .filter { !reusedIDs.contains($0.id) && $0.pid == app.processIdentifier && $0.title == title }
                        .min { lhs, rhs in
                            hypot(lhs.frame.midX - frame.midX, lhs.frame.midY - frame.midY)
                                < hypot(rhs.frame.midX - frame.midX, rhs.frame.midY - frame.midY)
                        }
                if let old { reusedIDs.insert(old.id) }
                // A minimized window reports odd bounds, and the WindowServer
                // number is matched by frame proximity — re-deriving it here
                // could hand the group a different window. Keep what we already
                // knew for as long as it stays minimized.
                let resolvedWindowID: CGWindowID?
                if minimized, let previous = old?.windowID {
                    resolvedWindowID = previous
                } else {
                    resolvedWindowID = matchingWindowID(
                        pid: app.processIdentifier,
                        title: title,
                        frame: frame,
                        descriptors: windowDescriptors
                    )
                }
                result.append(ManagedWindow(
                    id: old?.id ?? UUID(),
                    element: element,
                    windowID: resolvedWindowID,
                    pid: app.processIdentifier,
                    appName: app.localizedName ?? bundleID,
                    bundleIdentifier: bundleID,
                    title: title,
                    frame: frame,
                    minimumSize: minimumSize(of: element),
                    isMinimized: minimized,
                    isFullScreen: fullScreen,
                    isSelected: old?.isSelected ?? false
                ))
            }
        }
        return (result.sorted(by: ManagedWindow.precedesInReadingOrder), unsupported)
    }

    func previewImage(for window: ManagedWindow) -> NSImage? {
        guard let windowID = window.windowID else { return nil }
        return previewImage(forWindowID: windowID)
    }

    /// Safe to call off the main thread, which is the point: capturing every
    /// window before the chooser can draw made opening it visibly stall.
    func previewImage(forWindowID windowID: CGWindowID) -> NSImage? {
        guard canCaptureScreen,
              let image = CGWindowListCreateImage(
                .null,
                .optionIncludingWindow,
                windowID,
                [.boundsIgnoreFraming, .bestResolution]
              ) else { return nil }
        // This is enough for a 2× card-sized preview while bounding memory to
        // roughly 1.4 MB per RGBA thumbnail at the maximum dimensions.
        let maximumSize = CGSize(width: 720, height: 480)
        let scale = min(
            1,
            maximumSize.width / CGFloat(image.width),
            maximumSize.height / CGFloat(image.height)
        )
        let width = max(1, Int((CGFloat(image.width) * scale).rounded()))
        let height = max(1, Int((CGFloat(image.height) * scale).rounded()))
        guard let context = CGContext(
            data: nil,
            width: width,
            height: height,
            bitsPerComponent: 8,
            bytesPerRow: 0,
            space: CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        ) else { return nil }
        context.interpolationQuality = .medium
        context.draw(image, in: CGRect(x: 0, y: 0, width: width, height: height))
        guard let thumbnail = context.makeImage() else { return nil }
        return NSImage(cgImage: thumbnail, size: NSSize(width: width, height: height))
    }

    func setFrame(_ cocoaFrame: CGRect, of element: AXUIElement) throws -> CGRect {
        let current = frame(of: element)
        let axFrame = CoordinateConverter.cocoaToAccessibility(cocoaFrame)
        var position = axFrame.origin
        var size = axFrame.size
        guard let positionValue = AXValueCreate(.cgPoint, &position),
              let sizeValue = AXValueCreate(.cgSize, &size) else {
            throw LayoutError.accessibility("Could not encode a window frame.")
        }

        let positionChanged = current.map {
            abs($0.minX - cocoaFrame.minX) >= 0.5 || abs($0.minY - cocoaFrame.minY) >= 0.5
        } ?? true
        let sizeChanged = current.map {
            abs($0.width - cocoaFrame.width) >= 0.5 || abs($0.height - cocoaFrame.height) >= 0.5
        } ?? true

        var positionResult: AXError = .success
        var sizeResult: AXError = .success
        if positionChanged {
            positionResult = AXUIElementSetAttributeValue(element, kAXPositionAttribute as CFString, positionValue)
        }
        if sizeChanged {
            sizeResult = AXUIElementSetAttributeValue(element, kAXSizeAttribute as CFString, sizeValue)
        }
        guard positionResult == .success, sizeResult == .success else {
            throw LayoutError.accessibility("A window refused to move or resize (Accessibility error \(sizeResult.rawValue)).")
        }
        return frame(of: element) ?? cocoaFrame
    }

    /// Whether Accessibility calls actually succeed right now.
    ///
    /// `AXIsProcessTrusted()` caches its answer for the lifetime of the process:
    /// a process that was denied at launch keeps reporting "not trusted" however
    /// often it is asked, so polling it can never notice the user granting
    /// access. A real Accessibility call is answered by the target rather than
    /// by that cache, and returns `apiDisabled` when this process is untrusted.
    func canPerformAccessibilityCalls() -> Bool {
        guard let target = NSWorkspace.shared.runningApplications.first(where: {
            $0.activationPolicy == .regular
                && !$0.isTerminated
                && $0.processIdentifier != ProcessInfo.processInfo.processIdentifier
        }) else { return AXIsProcessTrusted() }
        var value: CFTypeRef?
        let result = AXUIElementCopyAttributeValue(
            AXUIElementCreateApplication(target.processIdentifier),
            kAXWindowsAttribute as CFString,
            &value
        )
        switch result {
        case .success, .noValue, .attributeUnsupported:
            return true
        default:
            // apiDisabled means untrusted; anything else is treated as "not yet"
            // so the caller simply polls again.
            return false
        }
    }

    func minimize(_ element: AXUIElement) {
        guard isSettable(kAXMinimizedAttribute as CFString, on: element) else { return }
        AXUIElementSetAttributeValue(element, kAXMinimizedAttribute as CFString, kCFBooleanTrue)
    }

    /// Checks whether a window is minimized.
    func isMinimized(_ element: AXUIElement) -> Bool {
        copyAttribute(kAXMinimizedAttribute as CFString, from: element) ?? false
    }

    /// Restores a minimized window. A minimized window cannot be raised or
    /// resized, so this has to happen before any layout pass.
    func unminimize(_ element: AXUIElement) {
        guard isSettable(kAXMinimizedAttribute as CFString, on: element) else { return }
        AXUIElementSetAttributeValue(element, kAXMinimizedAttribute as CFString, kCFBooleanFalse)
    }

    /// Checks whether a window is in native macOS full-screen mode.
    func isFullScreen(_ element: AXUIElement) -> Bool {
        var value: CFTypeRef?
        let result = AXUIElementCopyAttributeValue(element, "AXFullScreen" as CFString, &value)
        guard result == .success, let boolValue = value as? Bool else { return false }
        return boolValue
    }

    /// Window numbers of the on-screen windows, front to back.
    func onScreenWindowOrder() -> [CGWindowID] {
        guard let information = CGWindowListCopyWindowInfo(
            [.optionOnScreenOnly, .excludeDesktopElements],
            kCGNullWindowID
        ) as? [[String: Any]] else { return [] }
        return information.compactMap { item in
            guard (item[kCGWindowLayer as String] as? NSNumber)?.intValue == 0,
                  let number = item[kCGWindowNumber as String] as? NSNumber else { return nil }
            return CGWindowID(number.uint32Value)
        }
    }

    func window(at cocoaPoint: CGPoint) -> AXUIElement? {
        guard isTrusted else { return nil }
        let accessibilityPoint = CoordinateConverter.cocoaPointToAccessibility(cocoaPoint)
        var hitElement: AXUIElement?
        guard AXUIElementCopyElementAtPosition(
            AXUIElementCreateSystemWide(),
            Float(accessibilityPoint.x),
            Float(accessibilityPoint.y),
            &hitElement
        ) == .success else { return nil }

        var current = hitElement
        for _ in 0..<12 {
            guard let element = current else { return nil }
            let role: String? = copyAttribute(kAXRoleAttribute as CFString, from: element)
            if role == kAXWindowRole as String { return element }
            current = copyAttribute(kAXParentAttribute as CFString, from: element)
        }
        return nil
    }

    func currentFrame(of element: AXUIElement) -> CGRect? {
        frame(of: element)
    }

    func focusedWindowBelongs(to windows: [ManagedWindow]) -> Bool {
        guard let frontmostPID = NSWorkspace.shared.frontmostApplication?.processIdentifier,
              windows.contains(where: { $0.pid == frontmostPID }) else { return false }
        let appElement = AXUIElementCreateApplication(frontmostPID)
        guard let focused: AXUIElement = copyAttribute(
            kAXFocusedWindowAttribute as CFString,
            from: appElement
        ), let managed = windows.first(where: { CFEqual($0.element, focused) }) else {
            return false
        }
        return !managed.isMinimized
    }

    func observe(_ windows: [ManagedWindow], handler: @escaping (AXUIElement, String) -> Void) {
        stopObserving()
        for group in Dictionary(grouping: windows, by: \.pid) {
            let pid = group.key
            var observer: AXObserver?
            let result = AXObserverCreate(pid, accessibilityObserverCallback, &observer)
            guard result == .success, let observer else { continue }

            let context = ObserverContext(handler: handler)
            let pointer = Unmanaged.passUnretained(context).toOpaque()
            let appElement = AXUIElementCreateApplication(pid)
            AXObserverAddNotification(
                observer,
                appElement,
                kAXFocusedWindowChangedNotification as CFString,
                pointer
            )
            for window in group.value {
                AXObserverAddNotification(observer, window.element, kAXWindowResizedNotification as CFString, pointer)
                AXObserverAddNotification(observer, window.element, kAXWindowMovedNotification as CFString, pointer)
                AXObserverAddNotification(observer, window.element, kAXUIElementDestroyedNotification as CFString, pointer)
                AXObserverAddNotification(observer, window.element, kAXWindowMiniaturizedNotification as CFString, pointer)
            }
            CFRunLoopAddSource(CFRunLoopGetMain(), AXObserverGetRunLoopSource(observer), .commonModes)
            observers[pid] = ObserverRecord(observer: observer, context: context)
        }
    }

    func stopObserving() {
        for record in observers.values {
            CFRunLoopRemoveSource(CFRunLoopGetMain(), AXObserverGetRunLoopSource(record.observer), .commonModes)
        }
        observers.removeAll()
    }

    deinit { stopObserving() }

    private func frame(of element: AXUIElement) -> CGRect? {
        guard let positionValue: AXValue = copyAttribute(kAXPositionAttribute as CFString, from: element),
              let sizeValue: AXValue = copyAttribute(kAXSizeAttribute as CFString, from: element) else { return nil }
        var point = CGPoint.zero
        var size = CGSize.zero
        guard AXValueGetValue(positionValue, .cgPoint, &point), AXValueGetValue(sizeValue, .cgSize, &size) else { return nil }
        return CoordinateConverter.accessibilityToCocoa(CGRect(origin: point, size: size))
    }

    private func minimumSize(of element: AXUIElement) -> CGSize {
        if let value: AXValue = copyAttribute("AXMinSize" as CFString, from: element) {
            var size = CGSize.zero
            if AXValueGetValue(value, .cgSize, &size), size.width > 0 { return size }
        }
        // Accessibility does not require applications to expose AXMinSize. The OS still
        // enforces the real constraint; the coordinator reads the applied size back.
        return CGSize(width: 160, height: 120)
    }

    private func isSettable(_ attribute: CFString, on element: AXUIElement) -> Bool {
        var settable = DarwinBoolean(false)
        return AXUIElementIsAttributeSettable(element, attribute, &settable) == .success && settable.boolValue
    }

    private func copyAttribute<T>(_ attribute: CFString, from element: AXUIElement) -> T? {
        var value: CFTypeRef?
        guard AXUIElementCopyAttributeValue(element, attribute, &value) == .success else { return nil }
        return value as? T
    }

    private func currentWindowDescriptors() -> [WindowDescriptor] {
        guard let information = CGWindowListCopyWindowInfo(.optionAll, kCGNullWindowID) as? [[String: Any]] else {
            return []
        }
        return information.compactMap { item in
            guard let number = item[kCGWindowNumber as String] as? NSNumber,
                  let ownerPID = item[kCGWindowOwnerPID as String] as? NSNumber,
                  let bounds = item[kCGWindowBounds as String] as? NSDictionary,
                  let frame = CGRect(dictionaryRepresentation: bounds) else { return nil }
            let layer = (item[kCGWindowLayer as String] as? NSNumber)?.intValue ?? 0
            guard layer == 0 else { return nil }
            return WindowDescriptor(
                id: CGWindowID(number.uint32Value),
                pid: pid_t(ownerPID.int32Value),
                title: item[kCGWindowName as String] as? String ?? "",
                frame: CoordinateConverter.accessibilityToCocoa(frame)
            )
        }
    }

    private func matchingWindowID(
        pid: pid_t,
        title: String,
        frame: CGRect,
        descriptors: [WindowDescriptor]
    ) -> CGWindowID? {
        let candidates = descriptors.filter { $0.pid == pid }
        let titled = candidates.filter { !$0.title.isEmpty && $0.title == title }
        let pool = titled.isEmpty ? candidates : titled
        return pool.min { lhs, rhs in
            frameDistance(lhs.frame, frame) < frameDistance(rhs.frame, frame)
        }?.id
    }

    private func frameDistance(_ lhs: CGRect, _ rhs: CGRect) -> CGFloat {
        abs(lhs.midX - rhs.midX)
            + abs(lhs.midY - rhs.midY)
            + abs(lhs.width - rhs.width)
            + abs(lhs.height - rhs.height)
    }
}

private func accessibilityObserverCallback(
    observer: AXObserver,
    element: AXUIElement,
    notification: CFString,
    refcon: UnsafeMutableRawPointer?
) {
    guard let refcon else { return }
    // Resolve the handler synchronously. Holding the context across the hop and
    // dereferencing it later is a use-after-free if the observers are rebuilt in
    // between, which happens on every refresh.
    let handler = Unmanaged<AccessibilityService.ObserverContext>
        .fromOpaque(refcon)
        .takeUnretainedValue()
        .handler
    let name = notification as String
    DispatchQueue.main.async { handler(element, name) }
}

enum CoordinateConverter {
    private static let topLock = NSLock()
    private nonisolated(unsafe) static var _cachedPrimaryTop: CGFloat = {
        if Thread.isMainThread {
            return NSScreen.screens.first?.frame.maxY ?? 0
        }
        return 0
    }()

    private static var primaryTop: CGFloat {
        if Thread.isMainThread {
            let top = NSScreen.screens.first?.frame.maxY ?? 0
            topLock.lock()
            _cachedPrimaryTop = top
            topLock.unlock()
            return top
        }
        topLock.lock()
        defer { topLock.unlock() }
        return _cachedPrimaryTop
    }

    static func accessibilityToCocoa(_ frame: CGRect) -> CGRect {
        CGRect(x: frame.minX, y: primaryTop - frame.minY - frame.height, width: frame.width, height: frame.height)
    }

    static func cocoaToAccessibility(_ frame: CGRect) -> CGRect {
        CGRect(x: frame.minX, y: primaryTop - frame.maxY, width: frame.width, height: frame.height)
    }

    static func cocoaPointToAccessibility(_ point: CGPoint) -> CGPoint {
        CGPoint(x: point.x, y: primaryTop - point.y)
    }
}
