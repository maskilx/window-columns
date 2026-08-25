import AppKit
import SwiftUI

enum GroupPalette {
    static let colors: [Color] = [
        Color(red: 0.18, green: 0.52, blue: 0.98),
        Color(red: 0.55, green: 0.33, blue: 0.96),
        Color(red: 0.94, green: 0.30, blue: 0.48),
        Color(red: 0.98, green: 0.55, blue: 0.18),
        Color(red: 0.17, green: 0.72, blue: 0.53),
        Color(red: 0.10, green: 0.67, blue: 0.83),
        Color(red: 0.75, green: 0.42, blue: 0.20),
        Color(red: 0.46, green: 0.55, blue: 0.68),
        // Nine groups are supported and Scripts/make-group-icons.py generates
        // nine icon palettes, so the ninth colour has to exist here too or
        // Group 9's chip contradicts its own Dock icon.
        Color(red: 0.30, green: 0.72, blue: 0.33)
    ]

    static var count: Int { colors.count }

    static func color(at index: Int) -> Color {
        colors[index.nonnegativeModulo(colors.count)]
    }
}

private extension Int {
    func nonnegativeModulo(_ divisor: Int) -> Int {
        let remainder = self % divisor
        return remainder >= 0 ? remainder : remainder + divisor
    }
}
