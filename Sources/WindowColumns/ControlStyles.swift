import AppKit
import SwiftUI

enum ElegantButtonKind {
    case primary
    case secondary
    case destructive
}

struct ElegantButtonStyle: ButtonStyle {
    @Environment(\.isEnabled) private var isEnabled
    let kind: ElegantButtonKind
    var minWidth: CGFloat? = nil

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.system(size: 13, weight: .semibold))
            .lineLimit(1)
            .foregroundStyle(foregroundColor)
            .padding(.horizontal, 16)
            .frame(minWidth: minWidth, minHeight: 38)
            .background {
                RoundedRectangle(cornerRadius: 10, style: .continuous)
                    .fill(backgroundColor.opacity(configuration.isPressed ? 0.72 : 1))
            }
            .overlay {
                if kind != .primary {
                    RoundedRectangle(cornerRadius: 10, style: .continuous)
                        .strokeBorder(borderColor, lineWidth: 1)
                }
            }
            .contentShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
            .scaleEffect(configuration.isPressed ? 0.975 : 1)
            .opacity(isEnabled ? 1 : 0.45)
            .animation(.easeOut(duration: 0.1), value: configuration.isPressed)
    }

    private var foregroundColor: Color {
        switch kind {
        case .primary: .white
        case .secondary: .primary
        case .destructive: .red
        }
    }

    private var backgroundColor: Color {
        switch kind {
        case .primary: .accentColor
        case .secondary: Color(nsColor: .controlBackgroundColor)
        case .destructive: .red.opacity(0.1)
        }
    }

    private var borderColor: Color {
        switch kind {
        case .primary: .clear
        case .secondary: Color(nsColor: .separatorColor).opacity(0.9)
        case .destructive: .red.opacity(0.25)
        }
    }
}

struct ElegantIconButtonStyle: ButtonStyle {
    @Environment(\.isEnabled) private var isEnabled
    var destructive = false
    var size: CGFloat = 32

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.system(size: 13, weight: .semibold))
            .foregroundStyle(destructive ? Color.red : Color.primary)
            .frame(width: size, height: size)
            .background(
                (destructive ? Color.red.opacity(0.1) : Color(nsColor: .controlBackgroundColor))
                    .opacity(configuration.isPressed ? 0.65 : 1),
                in: RoundedRectangle(cornerRadius: size * 0.31, style: .continuous)
            )
            .overlay {
                RoundedRectangle(cornerRadius: size * 0.31, style: .continuous)
                    .strokeBorder(
                        destructive ? Color.red.opacity(0.22) : Color(nsColor: .separatorColor).opacity(0.8),
                        lineWidth: 1
                    )
            }
            .scaleEffect(configuration.isPressed ? 0.94 : 1)
            .opacity(isEnabled ? 1 : 0.45)
            .animation(.easeOut(duration: 0.1), value: configuration.isPressed)
    }
}
