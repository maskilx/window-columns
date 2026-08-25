import AppKit
import Foundation

@MainActor
final class WindowPicker {
    private var mouseMonitor: Any?
    private var keyMonitor: Any?
    private let coordinator: WindowCoordinator
    private let onUpdate: (Int) -> Void
    private let onFinish: (Bool) -> Void
    private var targetCount = 0

    init(
        coordinator: WindowCoordinator,
        onUpdate: @escaping (Int) -> Void,
        onFinish: @escaping (Bool) -> Void
    ) {
        self.coordinator = coordinator
        self.onUpdate = onUpdate
        self.onFinish = onFinish
    }

    func start(count: Int) {
        stop(notify: false)
        targetCount = count
        coordinator.refresh()
        coordinator.selectDisplay(containing: NSEvent.mouseLocation)
        coordinator.clearSelection()
        onUpdate(0)

        mouseMonitor = NSEvent.addGlobalMonitorForEvents(matching: .leftMouseDown) { [weak self] _ in
            let point = NSEvent.mouseLocation
            Task { @MainActor in self?.pickedWindow(at: point) }
        }
        keyMonitor = NSEvent.addGlobalMonitorForEvents(matching: .keyDown) { [weak self] event in
            Task { @MainActor in
                if event.keyCode == 53 { self?.stop(notify: true) } // Escape
                if event.keyCode == 36, (self?.coordinator.selectedWindows.count ?? 0) >= 2 {
                    self?.finishAndArrange()
                }
            }
        }
    }

    func cancel() {
        coordinator.clearSelection()
        stop(notify: true)
    }

    private func pickedWindow(at point: CGPoint) {
        guard coordinator.toggleWindow(at: point) else { return }
        let count = coordinator.selectedWindows.count
        onUpdate(count)
        if count == targetCount { finishAndArrange() }
    }

    private func finishAndArrange() {
        stop(notify: false)
        coordinator.arrangeEqualColumns()
        onFinish(true)
    }

    private func stop(notify: Bool) {
        if let mouseMonitor { NSEvent.removeMonitor(mouseMonitor) }
        if let keyMonitor { NSEvent.removeMonitor(keyMonitor) }
        mouseMonitor = nil
        keyMonitor = nil
        if notify { onFinish(false) }
    }

    deinit {
        if let mouseMonitor { NSEvent.removeMonitor(mouseMonitor) }
        if let keyMonitor { NSEvent.removeMonitor(keyMonitor) }
    }
}
