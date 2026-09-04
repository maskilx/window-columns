import AppKit

let width: CGFloat = 1280
let height: CGFloat = 640
let size = NSSize(width: width, height: height)

let rep = NSBitmapImageRep(
    bitmapDataPlanes: nil,
    pixelsWide: Int(width),
    pixelsHigh: Int(height),
    bitsPerSample: 8,
    samplesPerPixel: 4,
    hasAlpha: true,
    isPlanar: false,
    colorSpaceName: .deviceRGB,
    bytesPerRow: 0,
    bitsPerPixel: 0
)!

NSGraphicsContext.saveGraphicsState()
let ctx = NSGraphicsContext(bitmapImageRep: rep)!
NSGraphicsContext.current = ctx

// Background Gradient
let bgGradient = NSGradient(colors: [
    NSColor(calibratedRed: 0.05, green: 0.07, blue: 0.12, alpha: 1.0),
    NSColor(calibratedRed: 0.08, green: 0.11, blue: 0.18, alpha: 1.0)
])!
bgGradient.draw(in: NSRect(origin: .zero, size: size), angle: -45)

// Subtle decorative ambient glow circles
let glowGradient1 = NSGradient(colors: [
    NSColor(calibratedRed: 0.1, green: 0.5, blue: 0.9, alpha: 0.22),
    NSColor.clear
])!
glowGradient1.draw(in: NSRect(x: 100, y: 160, width: 360, height: 360), relativeCenterPosition: .zero)

let glowGradient2 = NSGradient(colors: [
    NSColor(calibratedRed: 0.0, green: 0.7, blue: 0.8, alpha: 0.12),
    NSColor.clear
])!
glowGradient2.draw(in: NSRect(x: 750, y: 100, width: 450, height: 450), relativeCenterPosition: .zero)

// Draw Icon
if let iconImage = NSImage(contentsOfFile: "Resources/AppIcon-v3-Dark.png") {
    let iconRect = NSRect(x: 140, y: 195, width: 250, height: 250)
    iconImage.draw(in: iconRect)
}

// Typography
let titleAttrs: [NSAttributedString.Key: Any] = [
    .font: NSFont.systemFont(ofSize: 58, weight: .heavy),
    .foregroundColor: NSColor.white
]
let title = NSAttributedString(string: "Window Columns", attributes: titleAttrs)
title.draw(at: NSPoint(x: 440, y: 340))

let subtitleAttrs: [NSAttributedString.Key: Any] = [
    .font: NSFont.systemFont(ofSize: 24, weight: .medium),
    .foregroundColor: NSColor(calibratedWhite: 0.72, alpha: 1.0)
]
let subtitle = NSAttributedString(
    string: "Native macOS window groups\nwith connected column layouts",
    attributes: subtitleAttrs
)
subtitle.draw(in: NSRect(x: 440, y: 245, width: 700, height: 80))

// Pills / Badges
let badges = ["Apple Silicon", "macOS 13+", "Zero Dependencies", "Open Source"]
var currentX: CGFloat = 440
let badgeY: CGFloat = 175
let badgeHeight: CGFloat = 36

for badge in badges {
    let badgeFont = NSFont.systemFont(ofSize: 14, weight: .semibold)
    let badgeTextAttrs: [NSAttributedString.Key: Any] = [
        .font: badgeFont,
        .foregroundColor: NSColor(calibratedWhite: 0.88, alpha: 1.0)
    ]
    let textSize = (badge as NSString).size(withAttributes: badgeTextAttrs)
    let badgeWidth = textSize.width + 28
    let badgeRect = NSRect(x: currentX, y: badgeY, width: badgeWidth, height: badgeHeight)

    let path = NSBezierPath(roundedRect: badgeRect, xRadius: 18, yRadius: 18)
    NSColor(calibratedWhite: 1.0, alpha: 0.08).setFill()
    path.fill()
    NSColor(calibratedWhite: 1.0, alpha: 0.16).setStroke()
    path.lineWidth = 1
    path.stroke()

    let textOrigin = NSPoint(x: currentX + 14, y: badgeY + (badgeHeight - textSize.height) / 2)
    (badge as NSString).draw(at: textOrigin, withAttributes: badgeTextAttrs)

    currentX += badgeWidth + 12
}

NSGraphicsContext.restoreGraphicsState()

if let pngData = rep.representation(using: .png, properties: [:]) {
    try? FileManager.default.createDirectory(atPath: "docs/assets", withIntermediateDirectories: true)
    let url = URL(fileURLWithPath: "docs/assets/social-preview.png")
    try pngData.write(to: url)
}
