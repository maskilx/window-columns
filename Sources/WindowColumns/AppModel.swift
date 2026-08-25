import AppKit
import Foundation
import ServiceManagement

@MainActor
final class AppModel: ObservableObject {
    static let shared = AppModel()
    @Published private(set) var hasActiveLayout = false
    @Published private(set) var pickingTarget: Int?
    @Published private(set) var pickedCount = 0
    /// Shortcuts macOS or another application refused to hand over.
    @Published private(set) var rejectedShortcuts: [String] = []
    let coordinator: WindowCoordinator
    let store: LayoutStore
    private let hotKeys = HotKeyManager()
    private var picker: WindowPicker?
    var showCreateGroup: (() -> Void)?
    var showChooser: (() -> Void)?

    init() {
        coordinator = WindowCoordinator()
        store = LayoutStore()
        coordinator.gap = store.preferences.gap
        coordinator.onLayoutStateChanged = { [weak self] active in
            self?.setLayoutActive(active)
        }

        hotKeys.handler = { [weak coordinator] count in
            coordinator?.refresh()
            coordinator?.arrangeEqualColumns(count: count)
        }
        hotKeys.createGroupHandler = { [weak self] in
            self?.showCreateGroup?()
        }
        hotKeys.undoHandler = { [weak coordinator] in
            coordinator?.undoLastArrangement()
        }
        hotKeys.minimizeGroupHandler = { [weak coordinator] in
            _ = coordinator?.minimizeGroup()
        }
        hotKeys.openChooserHandler = { [weak self] in
            self?.showChooser?()
        }
        rejectedShortcuts = hotKeys.apply(store.preferences)
        applyAppearance(store.preferences.appearance)

        picker = WindowPicker(
            coordinator: coordinator,
            onUpdate: { [weak self] count in self?.pickedCount = count },
            onFinish: { [weak self] _ in
                self?.pickingTarget = nil
                self?.pickedCount = 0
            }
        )
    }

    func updateGap(_ value: Double) {
        coordinator.gap = value
        store.preferences.gap = value
    }

    /// Forces the app's own windows to one appearance, or follows the system.
    func setAppearance(_ appearance: AppAppearance) {
        store.preferences.appearance = appearance
        applyAppearance(appearance)
    }

    private func applyAppearance(_ appearance: AppAppearance) {
        NSApp.appearance = appearance.nsAppearance
    }

    /// Re-registers every global shortcut after a binding changes.
    func reloadShortcuts() {
        rejectedShortcuts = hotKeys.apply(store.preferences)
    }

    func setShowWindowPreviews(_ enabled: Bool) {
        store.preferences.showWindowPreviews = enabled
    }

    func startPicking(count: Int) {
        pickingTarget = count
        pickedCount = 0
        picker?.start(count: count)
    }

    func cancelPicking() {
        picker?.cancel()
    }

    private func setLayoutActive(_ active: Bool) {
        guard hasActiveLayout != active else { return }
        hasActiveLayout = active
        // Individual group companions provide the Command-Tab entries. The controller
        // itself remains a lightweight menu-bar app so it doesn't add a duplicate tile.
        if NSApp.activationPolicy() != .accessory {
            NSApp.setActivationPolicy(.accessory)
        }
    }

    func setLaunchAtLogin(_ enabled: Bool) throws {
        if enabled { try SMAppService.mainApp.register() } else { try SMAppService.mainApp.unregister() }
        store.preferences.launchAtLogin = enabled
    }
}
