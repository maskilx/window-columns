import AppKit
import SwiftUI

enum MenuBarIcon {
    /// Produces a clean monochrome vector status bar icon matching the application's 3-column "W" branding.
    /// Configured as a native macOS template image (`isTemplate = true`), automatically adapting to Light,
    /// Dark, and accent-highlighted menu bars with crisp Retina rendering.
    static func make(for appearance: NSAppearance? = nil) -> NSImage {
        let image = NSImage(size: NSSize(width: 18, height: 18), flipped: false) { rect in
            guard let ctx = NSGraphicsContext.current?.cgContext else { return false }
            ctx.setFillColor(NSColor.black.cgColor)

            let scale = rect.width / 18.0
            func s(_ val: CGFloat) -> CGFloat { val * scale }
            let ox = rect.origin.x, oy = rect.origin.y

            // Column 1 (left)
            let p1 = CGMutablePath()
            p1.move(to: CGPoint(x: ox + s(1.2), y: oy + s(5.2)))
            p1.addLine(to: CGPoint(x: ox + s(1.2), y: oy + s(12.3)))
            p1.addArc(tangent1End: CGPoint(x: ox + s(1.2), y: oy + s(13.5)), tangent2End: CGPoint(x: ox + s(3.0), y: oy + s(13.1)), radius: s(1.4))
            p1.addLine(to: CGPoint(x: ox + s(4.0), y: oy + s(12.8)))
            p1.addArc(tangent1End: CGPoint(x: ox + s(5.4), y: oy + s(12.5)), tangent2End: CGPoint(x: ox + s(5.4), y: oy + s(11.0)), radius: s(1.4))
            p1.addLine(to: CGPoint(x: ox + s(5.4), y: oy + s(4.5)))
            p1.addArc(tangent1End: CGPoint(x: ox + s(5.4), y: oy + s(3.3)), tangent2End: CGPoint(x: ox + s(3.8), y: oy + s(3.6)), radius: s(1.4))
            p1.addLine(to: CGPoint(x: ox + s(2.4), y: oy + s(3.9)))
            p1.addArc(tangent1End: CGPoint(x: ox + s(1.2), y: oy + s(4.2)), tangent2End: CGPoint(x: ox + s(1.2), y: oy + s(5.6)), radius: s(1.4))
            p1.closeSubpath()

            // Column 2 (middle - taller)
            let p2 = CGMutablePath()
            p2.move(to: CGPoint(x: ox + s(6.9), y: oy + s(4.0)))
            p2.addLine(to: CGPoint(x: ox + s(6.9), y: oy + s(14.4)))
            p2.addArc(tangent1End: CGPoint(x: ox + s(6.9), y: oy + s(15.6)), tangent2End: CGPoint(x: ox + s(8.8), y: oy + s(15.2)), radius: s(1.4))
            p2.addLine(to: CGPoint(x: ox + s(9.7), y: oy + s(15.0)))
            p2.addArc(tangent1End: CGPoint(x: ox + s(11.1), y: oy + s(14.7)), tangent2End: CGPoint(x: ox + s(11.1), y: oy + s(13.2)), radius: s(1.4))
            p2.addLine(to: CGPoint(x: ox + s(11.1), y: oy + s(3.2)))
            p2.addArc(tangent1End: CGPoint(x: ox + s(11.1), y: oy + s(2.0)), tangent2End: CGPoint(x: ox + s(9.5), y: oy + s(2.3)), radius: s(1.4))
            p2.addLine(to: CGPoint(x: ox + s(8.1), y: oy + s(2.6)))
            p2.addArc(tangent1End: CGPoint(x: ox + s(6.9), y: oy + s(2.8)), tangent2End: CGPoint(x: ox + s(6.9), y: oy + s(4.2)), radius: s(1.4))
            p2.closeSubpath()

            // Column 3 (right)
            let p3 = CGMutablePath()
            p3.move(to: CGPoint(x: ox + s(12.6), y: oy + s(4.8)))
            p3.addLine(to: CGPoint(x: ox + s(12.6), y: oy + s(12.8)))
            p3.addArc(tangent1End: CGPoint(x: ox + s(12.6), y: oy + s(14.0)), tangent2End: CGPoint(x: ox + s(14.4), y: oy + s(13.6)), radius: s(1.4))
            p3.addLine(to: CGPoint(x: ox + s(15.4), y: oy + s(13.4)))
            p3.addArc(tangent1End: CGPoint(x: ox + s(16.8), y: oy + s(13.1)), tangent2End: CGPoint(x: ox + s(16.8), y: oy + s(11.6)), radius: s(1.4))
            p3.addLine(to: CGPoint(x: ox + s(16.8), y: oy + s(4.0)))
            p3.addArc(tangent1End: CGPoint(x: ox + s(16.8), y: oy + s(2.8)), tangent2End: CGPoint(x: ox + s(15.2), y: oy + s(3.1)), radius: s(1.4))
            p3.addLine(to: CGPoint(x: ox + s(13.8), y: oy + s(3.4)))
            p3.addArc(tangent1End: CGPoint(x: ox + s(12.6), y: oy + s(3.6)), tangent2End: CGPoint(x: ox + s(12.6), y: oy + s(5.0)), radius: s(1.4))
            p3.closeSubpath()

            ctx.addPath(p1)
            ctx.addPath(p2)
            ctx.addPath(p3)
            ctx.fillPath()
            return true
        }
        image.isTemplate = true
        image.accessibilityDescription = "Window Columns"
        return image
    }


    /// The dot that identifies a group in the status-bar menu, tinted to match
    /// that group's Command-Tab companion icon.
    static func groupDot(colorIndex: Int) -> NSImage {
        let color = NSColor(GroupPalette.color(at: colorIndex))
        let image = NSImage(size: NSSize(width: 12, height: 12), flipped: false) { _ in
            color.setFill()
            NSBezierPath(ovalIn: CGRect(x: 1, y: 1, width: 10, height: 10)).fill()
            return true
        }
        image.isTemplate = false
        return image
    }
}
