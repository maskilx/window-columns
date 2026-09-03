import AppKit

@MainActor
final class DropIndicatorController {
    private var panel: NSPanel?
    private let indicatorView = DropIndicatorView()

    init() {
        let p = NSPanel(
            contentRect: .zero,
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered,
            defer: false
        )
        p.level = .floating
        p.backgroundColor = .clear
        p.isOpaque = false
        p.hasShadow = false
        p.hidesOnDeactivate = false
        p.ignoresMouseEvents = true
        p.collectionBehavior = [.fullScreenAuxiliary, .transient, .ignoresCycle]
        p.contentView = indicatorView
        self.panel = p
    }

    func show(in frame: CGRect) {
        guard let panel else { return }
        // Inset slightly so it looks like an inner drop slot
        let inset = frame.insetBy(dx: 4, dy: 4)
        panel.setFrame(inset, display: true)
        panel.alphaValue = 1
        panel.orderFrontRegardless()
    }

    func hide() {
        guard let panel, panel.isVisible else { return }
        NSAnimationContext.runAnimationGroup { context in
            context.duration = 0.15
            panel.animator().alphaValue = 0
        } completionHandler: { [weak panel] in
            panel?.orderOut(nil)
        }
    }

    func close() {
        panel?.close()
        panel = nil
    }
}

private final class DropIndicatorView: NSView {
    override func draw(_ dirtyRect: NSRect) {
        super.draw(dirtyRect)
        let rect = bounds.insetBy(dx: 2, dy: 2)
        let path = NSBezierPath(roundedRect: rect, xRadius: 10, yRadius: 10)
        
        NSColor.controlAccentColor.withAlphaComponent(0.12).setFill()
        path.fill()

        NSColor.controlAccentColor.withAlphaComponent(0.5).setStroke()
        path.lineWidth = 2
        path.stroke()
    }
}
