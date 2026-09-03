import AppKit

@MainActor
final class DividerOverlayController {
    private let coordinator: WindowCoordinator
    private let dropIndicator = DropIndicatorController()
    private var panels: [NSPanel] = []
    private var frames: [CGRect] = []
    private var workspaceObservers: [NSObjectProtocol] = []
    private var draggingDivider: Int?

    init(coordinator: WindowCoordinator) {
        self.coordinator = coordinator
        coordinator.onLayoutFramesChanged = { [weak self] frames in
            self?.update(frames: frames)
        }
        coordinator.onFrontmostWindowChanged = { [weak self] in
            self?.render()
        }
        coordinator.onDropTargetChanged = { [weak self] targetFrame in
            if let targetFrame {
                self?.dropIndicator.show(in: targetFrame)
            } else {
                self?.dropIndicator.hide()
            }
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
        coordinator.onLayoutFramesChanged = nil
        coordinator.onFrontmostWindowChanged = nil
        coordinator.onDropTargetChanged = nil
        dropIndicator.close()
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
        let selected = coordinator.selectedWindows
        let activeFrames = selected.count >= 2 ? selected.map(\.frame) : self.frames
        guard activeFrames.count >= 2, coordinator.selectedGroupHasFocusedVisibleWindow() else {
            hidePanels()
            return
        }
        while panels.count < activeFrames.count - 1 {
            panels.append(makePanel(divider: panels.count))
        }
        for index in panels.indices {
            guard index < activeFrames.count - 1 else {
                panels[index].orderOut(nil)
                continue
            }
            if selected.indices.contains(index), selected.indices.contains(index + 1) {
                if selected[index].isFullScreen || selected[index + 1].isFullScreen ||
                   selected[index].isMinimized || selected[index + 1].isMinimized {
                    panels[index].orderOut(nil)
                    continue
                }
            }
            let leftFrame = activeFrames[index]
            let rightFrame = activeFrames[index + 1]

            // Windows must be horizontally adjacent with a small gap, never overlapping.
            let gap = rightFrame.minX - leftFrame.maxX
            guard gap >= -2, gap <= 40 else {
                panels[index].orderOut(nil)
                continue
            }

            // Windows must vertically overlap to share an edge.
            let top = min(leftFrame.maxY, rightFrame.maxY)
            let bottom = max(leftFrame.minY, rightFrame.minY)
            let verticalOverlap = top - bottom
            guard verticalOverlap >= 40 else {
                panels[index].orderOut(nil)
                continue
            }

            // Span the shared edge strictly inside the gap.
            let x = (leftFrame.maxX + rightFrame.minX) / 2
            let width = max(6, min(14, gap + 4))
            let panelFrame = CGRect(x: x - width / 2, y: bottom, width: width, height: verticalOverlap)
            panels[index].setFrame(panelFrame, display: true)
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
        coordinator.dragDivider(after: divider, by: delta)
    }

    private func finishDrag() {
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
        needsDisplay = true
    }

    override func mouseDragged(with event: NSEvent) {
        let current = NSEvent.mouseLocation.x
        guard let previous = lastScreenX else {
            lastScreenX = current
            return
        }
        lastScreenX = current
        let delta = current - previous
        onDrag(delta)
    }

    override func mouseUp(with event: NSEvent) {
        lastScreenX = nil
        needsDisplay = true
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
        let isDragging = lastScreenX != nil

        if isDragging {
            let guidePath = NSBezierPath()
            let guideX = bounds.midX
            guidePath.move(to: CGPoint(x: guideX, y: bounds.minY))
            guidePath.line(to: CGPoint(x: guideX, y: bounds.maxY))
            NSColor.controlAccentColor.withAlphaComponent(0.45).setStroke()
            guidePath.lineWidth = 1.5
            guidePath.stroke()
        }

        let width: CGFloat = isDragging ? 6 : (hovered ? 5 : 3.5)
        let height: CGFloat = isDragging ? 68 : 58
        let centre = (pointerY ?? bounds.midY)
            .clamped(to: (bounds.minY + height / 2)...(bounds.maxY - height / 2))
        let rect = CGRect(
            x: bounds.midX - width / 2,
            y: centre - height / 2,
            width: width,
            height: height
        )

        NSGraphicsContext.saveGraphicsState()
        let shadow = NSShadow()
        shadow.shadowColor = NSColor.black.withAlphaComponent(isDragging ? 0.35 : 0.22)
        shadow.shadowBlurRadius = isDragging ? 4 : 2.5
        shadow.shadowOffset = NSSize(width: 0, height: -1)
        shadow.set()

        let pillPath = NSBezierPath(roundedRect: rect, xRadius: width / 2, yRadius: width / 2)
        let fillColor: NSColor
        if isDragging {
            fillColor = .controlAccentColor
        } else if hovered {
            fillColor = .white
        } else {
            fillColor = NSColor.white.withAlphaComponent(0.82)
        }
        fillColor.setFill()
        pillPath.fill()

        let strokeColor = isDragging ? NSColor.white.withAlphaComponent(0.4) : NSColor.black.withAlphaComponent(0.18)
        strokeColor.setStroke()
        pillPath.lineWidth = 0.5
        pillPath.stroke()

        NSGraphicsContext.restoreGraphicsState()
    }
}

private extension CGFloat {
    func clamped(to range: ClosedRange<CGFloat>) -> CGFloat {
        guard range.lowerBound <= range.upperBound else { return range.lowerBound }
        return Swift.min(Swift.max(self, range.lowerBound), range.upperBound)
    }
}
