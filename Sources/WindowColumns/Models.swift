import AppKit
import Foundation
import WindowColumnsCore

typealias WindowFingerprint = WindowColumnsCore.WindowFingerprint


struct ManagedWindow: Identifiable {
    let id: UUID
    let element: AXUIElement
    let windowID: CGWindowID?
    let pid: pid_t
    let appName: String
    let bundleIdentifier: String
    var title: String
    var frame: CGRect
    var minimumSize: CGSize
    var isMinimized: Bool
    var isFullScreen: Bool
    var isSelected: Bool

    var fingerprint: WindowFingerprint {
        WindowFingerprint(
            bundleIdentifier: bundleIdentifier,
            title: title,
            windowNumber: windowID
        )
    }
}

extension ManagedWindow {
    /// Reading order across the screen: top band first, then left to right.
    ///
    /// The chooser used to list windows alphabetically by application, which
    /// scatters windows you think of as neighbours to opposite ends of the grid.
    /// Ordering by position lets you find a window by where it is rather than by
    /// reading every title. Vertical positions are banded so windows that are
    /// roughly level are treated as one row instead of being split by a few
    /// stray points.
    static func precedesInReadingOrder(_ lhs: ManagedWindow, _ rhs: ManagedWindow) -> Bool {
        // Cocoa's origin is bottom-left, so a larger minY is higher on screen.
        let lhsBand = (lhs.frame.minY / 100).rounded()
        let rhsBand = (rhs.frame.minY / 100).rounded()
        if lhsBand != rhsBand { return lhsBand > rhsBand }
        if lhs.frame.minX != rhs.frame.minX { return lhs.frame.minX < rhs.frame.minX }
        return (lhs.appName, lhs.title) < (rhs.appName, rhs.title)
    }
}

struct DisplayDescriptor: Identifiable, Hashable {
    let id: String
    let name: String
    let visibleFrame: CGRect
    let scale: CGFloat

    static func current() -> [DisplayDescriptor] {
        NSScreen.screens.map { screen in
            let number = (screen.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber)?.uint32Value ?? 0
            let stableID: String
            if let uuid = CGDisplayCreateUUIDFromDisplayID(number) {
                stableID = CFUUIDCreateString(nil, uuid.takeRetainedValue()) as String
            } else {
                stableID = "\(number)-\(Int(screen.frame.width))x\(Int(screen.frame.height))"
            }
            return DisplayDescriptor(
                id: stableID,
                name: screen.localizedName,
                visibleFrame: screen.visibleFrame,
                scale: screen.backingScaleFactor
            )
        }
    }
}

struct SavedLayout: Codable, Identifiable, Equatable {
    var id: UUID
    var name: String
    var displayID: String
    var gap: Double
    var ratios: [Double]
    var windows: [WindowFingerprint]
}

/// Which appearance the app forces on its own windows.
enum AppAppearance: String, Codable, CaseIterable, Identifiable {
    case system, light, dark

    var id: String { rawValue }

    var label: String {
        switch self {
        case .system: return "System"
        case .light: return "Light"
        case .dark: return "Dark"
        }
    }

    var symbol: String {
        switch self {
        case .system: return "circle.lefthalf.filled"
        case .light: return "sun.max"
        case .dark: return "moon"
        }
    }

    var nsAppearance: NSAppearance? {
        switch self {
        case .system: return nil
        case .light: return NSAppearance(named: .aqua)
        case .dark: return NSAppearance(named: .darkAqua)
        }
    }
}

enum SwitcherDesignStyle: String, Codable, CaseIterable, Identifiable {
    case modern = "modern"
    case classic = "classic"

    var id: String { rawValue }
    var label: String {
        switch self {
        case .modern: return "Modern (Concept A)"
        case .classic: return "Classic"
        }
    }
}

struct LayoutPreferences: Codable, Equatable {
    var gap: Double
    var launchAtLogin: Bool
    var showWindowPreviews: Bool
    var showDockIcon: Bool
    var appearance: AppAppearance
    var switcherDesignStyle: SwitcherDesignStyle
    var geminiAPIKey: String?
    /// Modifiers shared by the ⌃⌥⌘2 … ⌃⌥⌘9 column shortcuts.
    var columnModifierFlags: UInt
    var undoShortcut: ShortcutBinding?
    var openChooserShortcut: ShortcutBinding?
    var createGroupShortcut: ShortcutBinding?
    var minimizeGroupShortcut: ShortcutBinding?
    /// Double-tapping this modifier opens the chooser in "create group" mode.
    var doubleTapModifier: DoubleTapModifier
    var automaticallyChecksForUpdates: Bool
    var lastUpdateCheckDate: Date?

    static let defaultColumnModifiers = NSEvent.ModifierFlags([.control, .option, .command]).rawValue

    init(
        gap: Double = 8,
        launchAtLogin: Bool = false,
        showWindowPreviews: Bool = true,
        showDockIcon: Bool = false,
        appearance: AppAppearance = .system,
        switcherDesignStyle: SwitcherDesignStyle = .modern,
        geminiAPIKey: String? = nil,
        columnModifierFlags: UInt = LayoutPreferences.defaultColumnModifiers,
        undoShortcut: ShortcutBinding? = .undoDefault,
        openChooserShortcut: ShortcutBinding? = nil,
        createGroupShortcut: ShortcutBinding? = nil,
        minimizeGroupShortcut: ShortcutBinding? = .minimizeGroupDefault,
        doubleTapModifier: DoubleTapModifier = .control,
        automaticallyChecksForUpdates: Bool = true,
        lastUpdateCheckDate: Date? = nil
    ) {
        self.gap = gap
        self.launchAtLogin = launchAtLogin
        self.showWindowPreviews = showWindowPreviews
        self.showDockIcon = showDockIcon
        self.appearance = appearance
        self.switcherDesignStyle = switcherDesignStyle
        self.geminiAPIKey = geminiAPIKey
        self.columnModifierFlags = columnModifierFlags
        self.undoShortcut = undoShortcut
        self.openChooserShortcut = openChooserShortcut
        self.createGroupShortcut = createGroupShortcut
        self.minimizeGroupShortcut = minimizeGroupShortcut
        self.doubleTapModifier = doubleTapModifier
        self.automaticallyChecksForUpdates = automaticallyChecksForUpdates
        self.lastUpdateCheckDate = lastUpdateCheckDate
    }

    private enum CodingKeys: String, CodingKey {
        case gap, launchAtLogin, showWindowPreviews, showDockIcon, appearance, switcherDesignStyle, geminiAPIKey
        case columnModifierFlags, undoShortcut, openChooserShortcut, createGroupShortcut
        case doubleTapModifier, minimizeGroupShortcut
        case automaticallyChecksForUpdates, lastUpdateCheckDate
    }

    // Every key is optional on read so preferences written by an earlier build
    // still decode; a decode failure would silently reset the user's settings.
    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        gap = try container.decodeIfPresent(Double.self, forKey: .gap) ?? 8
        launchAtLogin = try container.decodeIfPresent(Bool.self, forKey: .launchAtLogin) ?? false
        showWindowPreviews = try container.decodeIfPresent(Bool.self, forKey: .showWindowPreviews) ?? true
        showDockIcon = try container.decodeIfPresent(Bool.self, forKey: .showDockIcon) ?? false
        appearance = try container.decodeIfPresent(AppAppearance.self, forKey: .appearance) ?? .system
        switcherDesignStyle = try container.decodeIfPresent(SwitcherDesignStyle.self, forKey: .switcherDesignStyle) ?? .modern
        geminiAPIKey = try container.decodeIfPresent(String.self, forKey: .geminiAPIKey)
        columnModifierFlags = try container.decodeIfPresent(UInt.self, forKey: .columnModifierFlags)
            ?? LayoutPreferences.defaultColumnModifiers
        undoShortcut = try container.decodeIfPresent(ShortcutBinding.self, forKey: .undoShortcut)
            ?? .undoDefault
        openChooserShortcut = try container.decodeIfPresent(ShortcutBinding.self, forKey: .openChooserShortcut)
        createGroupShortcut = try container.decodeIfPresent(ShortcutBinding.self, forKey: .createGroupShortcut)
        doubleTapModifier = try container.decodeIfPresent(DoubleTapModifier.self, forKey: .doubleTapModifier) ?? .control
        minimizeGroupShortcut = try container.decodeIfPresent(ShortcutBinding.self, forKey: .minimizeGroupShortcut)
            ?? .minimizeGroupDefault
        automaticallyChecksForUpdates = try container.decodeIfPresent(Bool.self, forKey: .automaticallyChecksForUpdates) ?? true
        lastUpdateCheckDate = try container.decodeIfPresent(Date.self, forKey: .lastUpdateCheckDate)
    }
}

struct WindowGroupSnapshot: Codable, Identifiable, Equatable {
    var id: UUID
    /// The name shown everywhere: `customName` when the user set one, otherwise
    /// "Group N" tracking the slot.
    var name: String
    /// Optional so groups saved before renaming existed still decode.
    var customName: String?
    var slot: Int
    var colorIndex: Int
    var displayID: String
    var gap: Double
    var ratios: [Double]
    var windows: [WindowFingerprint]
    var updatedAt: Date
}

enum LayoutError: LocalizedError, Identifiable {
    case permissionRequired
    case noWindowsSelected
    case displayUnavailable
    case insufficientSpace
    case accessibility(String)

    var id: String { errorDescription ?? UUID().uuidString }

    var errorDescription: String? {
        switch self {
        case .permissionRequired: return "Accessibility permission is required."
        case .noWindowsSelected: return "Select at least two windows."
        case .displayUnavailable: return "The selected display is no longer available."
        case .insufficientSpace: return "The display is too narrow for these windows and their minimum sizes."
        case .accessibility(let message): return message
        }
    }
}
