import AppKit
import SwiftUI

enum MenuBarIcon {
    static func make() -> NSImage {
        let image = NSImage(size: NSSize(width: 18, height: 18), flipped: false) { _ in
            let color = NSColor.labelColor

            // A window divided into full-height columns. The previous mark was
            // three free-standing bars with two connectors, which read as a
            // picket fence; the enclosing frame is what makes it a window.
            // Sized to sit at the same visual weight as neighbouring menu-bar
            // items: a shorter, thinner mark reads as timid next to them.
            let frame = CGRect(x: 0.6, y: 3.0, width: 16.8, height: 12.0)
            let stroke: CGFloat = 1.6
            let outline = NSBezierPath(
                roundedRect: frame.insetBy(dx: stroke / 2, dy: stroke / 2),
                xRadius: 2.4,
                yRadius: 2.4
            )
            color.setStroke()
            outline.lineWidth = stroke
            outline.stroke()

            let dividers = NSBezierPath()
            dividers.lineWidth = stroke
            for fraction in [1.0 / 3.0, 2.0 / 3.0] {
                let x = frame.minX + frame.width * fraction
                dividers.move(to: CGPoint(x: x, y: frame.minY + stroke / 2))
                dividers.line(to: CGPoint(x: x, y: frame.maxY - stroke / 2))
            }
            dividers.stroke()
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
