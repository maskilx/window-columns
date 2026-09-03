import AppKit
import Foundation

@MainActor
final class GroupHostManager {
    private let coordinator: WindowCoordinator
    private var observers: [NSObjectProtocol] = []
    private var workspaceObservers: [NSObjectProtocol] = []
    private var running: [UUID: NSRunningApplication] = [:]
    private var groupIDByPID: [pid_t: UUID] = [:]
    private var expectedTerminations: Set<pid_t> = []
    private var relaunchWorkItems: [UUID: DispatchWorkItem] = [:]
    private var lastStructure: [UUID: Int] = [:]
    private var hasCompletedInitialSync = false
    /// Set while the machine is logging out, restarting, or this app is quitting.
    /// Companions die en masse in those moments and must not be mistaken for the
    /// user dismantling their groups.
    private var isShuttingDown = false
    /// Group ids whose companion announced a deliberate quit, with the moment it
    /// said so; anything else that dies is treated as a crash.
    private var announcedQuits: [UUID: Date] = [:]
    private var crashRelaunches: [UUID: Date] = [:]

    init(coordinator: WindowCoordinator) {
        self.coordinator = coordinator
        observers.append(DistributedNotificationCenter.default().addObserver(
            forName: GroupHostChannel.activationRequest,
            object: nil,
            queue: .main
        ) { [weak self] notification in
            guard let value = notification.object as? String,
                  let request = GroupHostChannel.decodeRequest(value) else { return }
            Task { @MainActor in
                self?.handleActivationRequest(groupID: request.groupID, helperPID: request.helperPID)
            }
        })

        observers.append(DistributedNotificationCenter.default().addObserver(
            forName: GroupHostChannel.minimizeRequest,
            object: nil,
            queue: .main
        ) { [weak self] notification in
            guard let value = notification.object as? String, let id = UUID(uuidString: value) else { return }
            Task { @MainActor in _ = self?.coordinator.minimizeGroup(id) }
        })

        observers.append(DistributedNotificationCenter.default().addObserver(
            forName: GroupHostChannel.companionQuitting,
            object: nil,
            queue: .main
        ) { [weak self] notification in
            guard let value = notification.object as? String, let id = UUID(uuidString: value) else { return }
            Task { @MainActor in self?.announcedQuits[id] = Date() }
        })

        let workspaceCenter = NSWorkspace.shared.notificationCenter
        workspaceObservers.append(workspaceCenter.addObserver(
            forName: NSWorkspace.didTerminateApplicationNotification,
            object: nil,
            queue: .main
        ) { [weak self] notification in
            guard let application = notification.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication else {
                return
            }
            Task { @MainActor in
                guard let self else { return }
                self.companionTerminated(pid: application.processIdentifier)
                // Reconcile unconditionally: a companion can also disappear
                // without ever having been recorded, and a group must never be
                // left without its Command-Tab entry.
                self.synchronize(with: self.coordinator.groups)
            }
        })
        workspaceObservers.append(workspaceCenter.addObserver(
            forName: NSWorkspace.willPowerOffNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            Task { @MainActor in self?.isShuttingDown = true }
        })

        coordinator.onGroupsChanged = { [weak self] groups in
            self?.synchronize(with: groups)
        }
        // A rename changes no structure, so no companion is relaunched; the
        // running one just refreshes its Dock badge.
        coordinator.onGroupRenamed = { group in
            DistributedNotificationCenter.default().postNotificationName(
                GroupHostChannel.groupRenamed,
                object: "\(group.id.uuidString)|\(group.name)",
                userInfo: nil,
                deliverImmediately: true
            )
        }
        synchronize(with: coordinator.groups)
    }

    // MARK: - Activation

    private func handleActivationRequest(groupID: UUID, helperPID: pid_t?) {
        // Trust the helper's own report of which group it stands for, but only
        // if we still recognise that group.
        let restored = coordinator.activateGroup(groupID, activationDonorPID: helperPID)
        DistributedNotificationCenter.default().postNotificationName(
            restored ? GroupHostChannel.activationSucceeded : GroupHostChannel.activationFailed,
            object: groupID.uuidString,
            userInfo: nil,
            deliverImmediately: true
        )
    }

    // MARK: - Companion lifecycle

    func synchronize(with groups: [WindowGroupSnapshot]) {
        let structure = Dictionary(uniqueKeysWithValues: groups.map { ($0.id, $0.slot) })
        // Drop companions that vanished without a usable termination notice so a
        // group is never left without its Command-Tab entry.
        let vanished = running.filter { $0.value.isTerminated }.map(\.key)
        for id in vanished {
            if let application = running.removeValue(forKey: id) {
                groupIDByPID.removeValue(forKey: application.processIdentifier)
            }
        }
        let needsRelaunch = groups.contains { running[$0.id] == nil && relaunchWorkItems[$0.id] == nil }
        guard !hasCompletedInitialSync || structure != lastStructure || needsRelaunch else { return }
        let isInitialSync = !hasCompletedInitialSync
        hasCompletedInitialSync = true
        let previousStructure = lastStructure
        lastStructure = structure

        // Recover from a helper left behind by a crash or an older build even
        // when there are currently no saved groups.
        let occupiedSlots = Set(groups.map(\.slot))
        for slot in 0..<9 where !occupiedSlots.contains(slot) {
            for application in companions(inSlot: slot) {
                terminateCompanion(application, expected: groupIDByPID[application.processIdentifier] != nil)
            }
        }

        let validIDs = Set(groups.map(\.id))
        let removedIDs = running.keys.filter { id in
            !validIDs.contains(id) || previousStructure[id] != structure[id]
        }
        for id in removedIDs {
            if let application = running.removeValue(forKey: id) {
                terminateCompanion(application, expected: true)
            }
        }
        for id in relaunchWorkItems.keys where !validIDs.contains(id) {
            relaunchWorkItems.removeValue(forKey: id)?.cancel()
        }

        for group in groups where running[group.id] == nil {
            let isNewGroup = !isInitialSync && previousStructure[group.id] == nil
            launchCompanion(for: group, bringForward: isNewGroup)
        }
    }

    func stopAll() {
        isShuttingDown = true
        relaunchWorkItems.values.forEach { $0.cancel() }
        relaunchWorkItems.removeAll()
        for application in running.values {
            terminateCompanion(application, expected: true)
        }
        running.removeAll()
        for slot in 0..<9 {
            for application in companions(inSlot: slot) {
                terminateCompanion(application, expected: groupIDByPID[application.processIdentifier] != nil)
            }
        }
    }

    private func companions(inSlot slot: Int) -> [NSRunningApplication] {
        NSRunningApplication.runningApplications(
            withBundleIdentifier: "com.adimaskil.WindowColumns.Group\(slot + 1)"
        )
    }

    private func launchCompanion(for group: WindowGroupSnapshot, bringForward: Bool = false) {
        guard group.slot >= 0, group.slot < 9 else { return }
        relaunchWorkItems.removeValue(forKey: group.id)?.cancel()
        let name = "Window Group \(group.slot + 1).app"
        let url = Bundle.main.bundleURL
            .appendingPathComponent("Contents", isDirectory: true)
            .appendingPathComponent("Helpers", isDirectory: true)
            .appendingPathComponent(name, isDirectory: true)
        guard FileManager.default.fileExists(atPath: url.path) else { return }

        let staleApplications = companions(inSlot: group.slot)
        if !staleApplications.isEmpty {
            staleApplications.forEach { terminateCompanion($0, expected: false) }
            let retry = DispatchWorkItem { [weak self] in
                guard let self else { return }
                self.relaunchWorkItems.removeValue(forKey: group.id)
                guard let current = self.coordinator.groups.first(where: { $0.id == group.id }),
                      current.slot == group.slot,
                      self.running[group.id] == nil else { return }
                self.launchCompanion(for: current, bringForward: bringForward)
            }
            relaunchWorkItems[group.id] = retry
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.2, execute: retry)
            return
        }

        let configuration = NSWorkspace.OpenConfiguration()
        configuration.activates = bringForward
        configuration.addsToRecentItems = false
        configuration.arguments = [
            "--group-id", group.id.uuidString,
            "--group-name", group.name,
            "--ignore-first-activation", bringForward ? "true" : "false"
        ]
        NSWorkspace.shared.openApplication(at: url, configuration: configuration) { [weak self] application, _ in
            guard let application else { return }
            Task { @MainActor in
                guard let self,
                      self.coordinator.groups.contains(where: { $0.id == group.id && $0.slot == group.slot }) else {
                    self?.terminateCompanion(application, expected: false)
                    return
                }
                self.running[group.id] = application
                self.groupIDByPID[application.processIdentifier] = group.id
                if bringForward {
                    application.activate(options: [.activateIgnoringOtherApps])
                }
            }
        }
    }

    private func companionTerminated(pid: pid_t) {
        guard let groupID = groupIDByPID.removeValue(forKey: pid) else { return }
        running.removeValue(forKey: groupID)
        if expectedTerminations.remove(pid) != nil { return }
        // Logout, restart, and our own quit terminate every companion at once.
        // Deleting the user's groups there would silently wipe their setup.
        guard !isShuttingDown else { return }

        // A companion that announced itself was quit on purpose, which is how
        // the Dock and Command-Tab entry dismantles a group. One that vanished
        // without announcing crashed or was killed, and a crash must not
        // destroy the group — rebuild it instead.
        let announced = announcedQuits.removeValue(forKey: groupID)
        let wasDeliberate = announced.map { Date().timeIntervalSince($0) < 5 } ?? false
        guard !wasDeliberate else {
            coordinator.deleteGroup(groupID)
            return
        }
        // Rate limited so a companion that crashes on launch cannot spin.
        let lastRelaunch = crashRelaunches[groupID] ?? .distantPast
        guard Date().timeIntervalSince(lastRelaunch) > 30,
              let group = coordinator.groups.first(where: { $0.id == groupID }) else { return }
        crashRelaunches[groupID] = Date()
        launchCompanion(for: group)
    }

    private func terminateCompanion(_ application: NSRunningApplication, expected: Bool) {
        if expected {
            expectedTerminations.insert(application.processIdentifier)
        }
        // Helpers contain no user data and intentionally run only a dispatch
        // loop, so stop them atomically to prevent orphaned Command-Tab entries.
        _ = application.forceTerminate()
    }

    deinit {
        for observer in observers {
            DistributedNotificationCenter.default().removeObserver(observer)
        }
        for observer in workspaceObservers {
            NSWorkspace.shared.notificationCenter.removeObserver(observer)
        }
    }
}
