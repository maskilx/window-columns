import AppKit
import Foundation
import ServiceManagement

@MainActor
final class AppModel: ObservableObject {
    static let shared = AppModel()
    @Published private(set) var hasActiveLayout = false
    /// Shortcuts macOS or another application refused to hand over.
    @Published private(set) var rejectedShortcuts: [String] = []
    let coordinator: WindowCoordinator
    let store: LayoutStore
    let updateService = UpdateService.shared
    private let hotKeys = HotKeyManager()
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

    var switcherDesignStyle: SwitcherDesignStyle {
        store.preferences.switcherDesignStyle
    }

    func setSwitcherDesignStyle(_ style: SwitcherDesignStyle) {
        store.preferences.switcherDesignStyle = style
        objectWillChange.send()
    }

    var geminiAPIKey: String {
        get { store.preferences.geminiAPIKey ?? "" }
        set {
            let trimmed = newValue.trimmingCharacters(in: .whitespacesAndNewlines)
            store.preferences.geminiAPIKey = trimmed.isEmpty ? nil : trimmed
            objectWillChange.send()
        }
    }

    func setShowDockIcon(_ enabled: Bool) {
        store.preferences.showDockIcon = enabled
        let targetPolicy: NSApplication.ActivationPolicy = enabled ? .regular : .accessory
        if NSApp.activationPolicy() != targetPolicy {
            NSApp.setActivationPolicy(targetPolicy)
        }
    }

    private func setLayoutActive(_ active: Bool) {
        guard hasActiveLayout != active else { return }
        hasActiveLayout = active
        let targetPolicy: NSApplication.ActivationPolicy = store.preferences.showDockIcon ? .regular : .accessory
        if NSApp.activationPolicy() != targetPolicy {
            NSApp.setActivationPolicy(targetPolicy)
        }
    }

    func setLaunchAtLogin(_ enabled: Bool) throws {
        if enabled { try SMAppService.mainApp.register() } else { try SMAppService.mainApp.unregister() }
        store.preferences.launchAtLogin = enabled
    }

    func checkForUpdates(interactive: Bool = true) {
        updateService.checkForUpdates(store: store, interactive: interactive)
    }
}
