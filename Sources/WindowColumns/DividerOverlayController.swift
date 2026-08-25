import AppKit

@MainActor
final class DividerOverlayController {
    private let coordinator: WindowCoordinator
    private var panels: [NSPanel] = []
    private var frames: [CGRect] = []
    private var workspaceObservers: [NSObjectProtocol] = []
    private var pendingDragDeltas: [Int: CGFloat] = [:]
    private var resizeWorkItem: DispatchWorkItem?
    private var draggingDivider: Int?

    init(coordinator: WindowCoordinator) {
        self.coordinator = coordinator
        coordinator.onLayoutFramesChanged = { [weak self] frames in
            self?.update(frames: frames)
        }
        coordinator.onFrontmostWindowChanged = { [weak self] in
            self?.render()
        }
        let workspaceCenter = NSWorkspace.shared.notificationCenter
        for name in [
            NSWorkspace.didActivateApplicationNotification,
            NSWorkspace.didHideApplicationNotification,
            NSWorkspace.didUnhideApplicationNotification,
            NSWorkspace.activeSpaceDidChangeNotification
        ] {
            workspaceObservers.append(workspaceCenter.addObserver(
                forName: name,
                object: nil,
                queue: .main
            ) { [weak self] notification in
                Task { @MainActor in self?.workspaceChanged(notification.name) }
            })
        }
        update(frames: coordinator.selectedWindows.map(\.frame))
    }

    func close() {
        resizeWorkItem?.cancel()
        resizeWorkItem = nil
        pendingDragDeltas.removeAll()
        coordinator.onLayoutFramesChanged = nil
        coordinator.onFrontmostWindowChanged = nil
        for observer in workspaceObservers {
            NSWorkspace.shared.notificationCenter.removeObserver(observer)
        }
        workspaceObservers.removeAll()
        panels.forEach { $0.close() }
        panels.removeAll()
    }

    private func update(frames: [CGRect]) {
        self.frames = frames
        render()
    }

    private func render() {
        guard frames.count >= 2, coordinator.selectedGroupHasFocusedVisibleWindow() else {
            hidePanels()
            return
        }
        while panels.count < frames.count - 1 {
            panels.append(makePanel(divider: panels.count))
        }
        for index in panels.indices {
            guard index < frames.count - 1 else {
                panels[index].orderOut(nil)
                continue
            }
            if index == draggingDivider {
                panels[index].orderFrontRegardless()
                continue
            }
            // Span the whole shared edge. The grab target used to be a 92 pt
            // pill at the vertical midpoint of a column that is typically ~868 pt
            // tall, so resizing meant hunting for a narrow band in the middle.
            let x = (frames[index].maxX + frames[index + 1].minX) / 2
            let top = min(frames[index].maxY, frames[index + 1].maxY)
            let bottom = max(frames[index].minY, frames[index + 1].minY)
            let gap = frames[index + 1].minX - frames[index].maxX
            // Stay inside the gap where there is one, so a zero-gap layout does
            // not swallow clicks along the full height of both windows.
            let width = max(6, min(14, gap + 4))
            panels[index].setFrame(
                CGRect(x: x - width / 2, y: bottom, width: width, height: max(24, top - bottom)),
                display: true
            )
            panels[index].orderFrontRegardless()
        }
    }

    private func makePanel(divider: Int) -> NSPanel {
        let panel = NSPanel(
            contentRect: CGRect(x: 0, y: 0, width: 10, height: 200),
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered,
            defer: false
        )
        panel.level = .floating
        panel.backgroundColor = .clear
        panel.isOpaque = false
        panel.hasShadow = false
        panel.hidesOnDeactivate = false
        // Never carry a divider onto another Space. It is recreated over the
        // group only when one of that group's exact windows is focused there.
        panel.collectionBehavior = [.fullScreenAuxiliary, .transient, .ignoresCycle]
        panel.contentView = DividerHandleView(
            onDrag: { [weak self] delta in
                self?.queueDrag(after: divider, by: delta)
            },
            onEnd: { [weak self] in
                self?.finishDrag()
            }
        )
        return panel
    }

    private func workspaceChanged(_ name: Notification.Name) {
        // Hide synchronously to prevent one-frame leftovers during Command-Tab
        // and Space transitions, then re-evaluate after macOS updates focus.
        hidePanels()
        let delay = name == NSWorkspace.activeSpaceDidChangeNotification ? 0.08 : 0.04
        DispatchQueue.main.asyncAfter(deadline: .now() + delay) { [weak self] in
            self?.render()
        }
    }

    private func hidePanels() {
        panels.forEach {
            ($0.contentView as? DividerHandleView)?.prepareForHide()
            $0.orderOut(nil)
        }
    }

    private func queueDrag(after divider: Int, by delta: CGFloat) {
        draggingDivider = divider
        pendingDragDeltas[divider, default: 0] += delta
        guard resizeWorkItem == nil else { return }
        let item = DispatchWorkItem { [weak self] in
            self?.flushPendingDrag()
        }
        resizeWorkItem = item
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.0 / 60.0, execute: item)
    }

    private func flushPendingDrag() {
        resizeWorkItem = nil
        let deltas = pendingDragDeltas
        pendingDragDeltas.removeAll(keepingCapacity: true)
        for (divider, delta) in deltas where abs(delta) > 0.01 {
            coordinator.dragDivider(after: divider, by: delta)
        }
    }

    private func finishDrag() {
        resizeWorkItem?.cancel()
        resizeWorkItem = nil
        flushPendingDrag()
        coordinator.finishDividerDrag { [weak self] in
            self?.draggingDivider = nil
            self?.render()
        }
    }
}

private final class DividerHandleView: NSView {
    private let onDrag: (CGFloat) -> Void
    private let onEnd: () -> Void
    private var lastScreenX: CGFloat?
    private var hovered = false
    private var trackingAreaReference: NSTrackingArea?
    /// Where to draw the pill. The hit target is the full column height, but
    /// showing a full-height bar would be a heavy piece of chrome sitting
    /// between every pair of windows, so only a short pill is drawn and it
    /// follows the pointer.
    private var pointerY: CGFloat?

    init(onDrag: @escaping (CGFloat) -> Void, onEnd: @escaping () -> Void) {
        self.onDrag = onDrag
        self.onEnd = onEnd
        super.init(frame: .zero)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { nil }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        if let trackingAreaReference { removeTrackingArea(trackingAreaReference) }
        let area = NSTrackingArea(
            rect: bounds,
            options: [.activeAlways, .mouseEnteredAndExited, .mouseMoved, .inVisibleRect],
            owner: self
        )
        addTrackingArea(area)
        trackingAreaReference = area
    }

    override func mouseEntered(with event: NSEvent) {
        hovered = true
        pointerY = convert(event.locationInWindow, from: nil).y
        needsDisplay = true
        NSCursor.resizeLeftRight.set()
    }

    override func mouseMoved(with event: NSEvent) {
        pointerY = convert(event.locationInWindow, from: nil).y
        needsDisplay = true
        NSCursor.resizeLeftRight.set()
    }

    override func mouseExited(with event: NSEvent) {
        hovered = false
        pointerY = nil
        needsDisplay = true
        NSCursor.arrow.set()
    }

    override func mouseDown(with event: NSEvent) {
        lastScreenX = NSEvent.mouseLocation.x
    }

    override func mouseDragged(with event: NSEvent) {
        let current = NSEvent.mouseLocation.x
        guard let previous = lastScreenX else {
            lastScreenX = current
            return
        }
        lastScreenX = current
        let delta = current - previous
        if let panel = window as? NSPanel {
            panel.setFrameOrigin(CGPoint(x: panel.frame.minX + delta, y: panel.frame.minY))
        }
        onDrag(delta)
    }

    override func mouseUp(with event: NSEvent) {
        lastScreenX = nil
        onEnd()
    }

    func prepareForHide() {
        guard hovered else { return }
        hovered = false
        pointerY = nil
        needsDisplay = true
        NSCursor.arrow.set()
    }

    override func draw(_ dirtyRect: NSRect) {
        super.draw(dirtyRect)
        let width: CGFloat = hovered ? 5 : 3
        let height: CGFloat = 56
        let centre = (pointerY ?? bounds.midY)
            .clamped(to: (bounds.minY + height / 2)...(bounds.maxY - height / 2))
        let rect = CGRect(
            x: bounds.midX - width / 2,
            y: centre - height / 2,
            width: width,
            height: height
        )
        let color = NSColor.white.withAlphaComponent(hovered ? 1.0 : 0.78)
        color.setFill()
        NSBezierPath(roundedRect: rect, xRadius: width / 2, yRadius: width / 2).fill()
    }
}

private extension CGFloat {
    func clamped(to range: ClosedRange<CGFloat>) -> CGFloat {
        guard range.lowerBound <= range.upperBound else { return range.lowerBound }
        return Swift.min(Swift.max(self, range.lowerBound), range.upperBound)
    }
}
