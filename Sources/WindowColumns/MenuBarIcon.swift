import AppKit
import SwiftUI

enum MenuBarIcon {
    /// Produces the menu bar status item icon matching the application's Dock icon.
    /// Adapts to Light and Dark mode appearances, scaling sharply for Retina displays.
    static func make(for appearance: NSAppearance? = nil) -> NSImage {
        let isDark = (appearance ?? NSApp.effectiveAppearance).bestMatch(from: [.darkAqua, .aqua]) == .darkAqua
        let resource = isDark ? "AppIcon-v3-Dark" : "AppIcon-v3-Light"

        let loadedImage: NSImage? = {
            if let url = Bundle.main.url(forResource: resource, withExtension: "png"),
               let img = NSImage(contentsOf: url) {
                return img
            }
            if let url = Bundle.main.url(forResource: "AppIcon-v3", withExtension: "icns"),
               let img = NSImage(contentsOf: url) {
                return img
            }
            // Fallback for development if running directly from Xcode/SPM without bundle resources
            let projectResourceURL = URL(fileURLWithPath: #file)
                .deletingLastPathComponent()
                .deletingLastPathComponent()
                .deletingLastPathComponent()
                .appendingPathComponent("Resources")
                .appendingPathComponent("\(resource).png")
            if let img = NSImage(contentsOf: projectResourceURL) {
                return img
            }
            return NSApp.applicationIconImage
        }()

        guard let source = loadedImage else {
            return fallbackWireframe()
        }

        let targetSize = NSSize(width: 18, height: 18)
        let image = NSImage(size: targetSize, flipped: false) { rect in
            source.draw(
                in: rect,
                from: NSRect(origin: .zero, size: source.size),
                operation: .sourceOver,
                fraction: 1.0
            )
            return true
        }
        image.isTemplate = false
        image.accessibilityDescription = "Window Columns"
        return image
    }

    /// Wireframe fallback in case image assets cannot be located.
    private static func fallbackWireframe() -> NSImage {
        let image = NSImage(size: NSSize(width: 18, height: 18), flipped: false) { _ in
            let color = NSColor.labelColor
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
