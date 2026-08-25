import AppKit
import SwiftUI

struct MenuContentView: View {
    @ObservedObject var model: AppModel
    @ObservedObject private var coordinator: WindowCoordinator
    @ObservedObject private var store: LayoutStore
    @State private var saveName = ""
    @State private var showWindowList = false
    @State private var pickCount = 3

    init(model: AppModel) {
        self.model = model
        coordinator = model.coordinator
        store = model.store
    }

    var body: some View {
        Group {
            if coordinator.isTrusted { mainContent } else { OnboardingView(coordinator: coordinator) }
        }
        .frame(width: 370)
        .onAppear { coordinator.refresh() }
        .alert(item: $coordinator.lastError) { error in
            Alert(title: Text("Window Columns"), message: Text(error.localizedDescription))
        }
    }

    private var mainContent: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Label("Window Columns", systemImage: "rectangle.split.3x1")
                    .font(.headline)
                Spacer()
                if coordinator.isApplyingLayout { ProgressView().controlSize(.small) }
                Button { coordinator.refresh() } label: { Image(systemName: "arrow.clockwise") }
                    .buttonStyle(ElegantIconButtonStyle())
                    .help("Refresh windows")
            }

            Picker("Display", selection: $coordinator.selectedDisplayID) {
                ForEach(coordinator.displays) { display in Text(display.name).tag(display.id) }
            }

            if let target = model.pickingTarget {
                VStack(alignment: .leading, spacing: 8) {
                    Label("Click \(target - model.pickedCount) more window\(target - model.pickedCount == 1 ? "" : "s")", systemImage: "cursorarrow.click.2")
                        .font(.headline)
                    Text("Click windows directly on screen. The layout starts automatically after window \(target).")
                        .font(.caption).foregroundStyle(.secondary)
                    Button("Cancel picking") { model.cancelPicking() }
                        .buttonStyle(ElegantButtonStyle(kind: .secondary))
                }
                .padding(10)
                .background(.tint.opacity(0.1), in: RoundedRectangle(cornerRadius: 8))
            } else {
                VStack(alignment: .leading, spacing: 7) {
                    Text("Pick windows on screen").font(.subheadline.weight(.semibold))
                    HStack {
                        Stepper("\(pickCount) windows", value: $pickCount, in: 2...9)
                        Spacer()
                        Button { model.startPicking(count: pickCount) } label: {
                            Label("Start Picking", systemImage: "cursorarrow.click.2")
                        }
                            .buttonStyle(ElegantButtonStyle(kind: .primary))
                            .help("Click \(pickCount) windows, then arrange them")
                    }
                    Text("Choose an amount, then click those windows anywhere on your desktop.")
                        .font(.caption).foregroundStyle(.secondary)
                }
            }

            HStack {
                Text("Gap")
                Slider(value: Binding(
                    get: { coordinator.gap },
                    set: { model.updateGap($0) }
                ), in: 0...32, step: 1)
                Text("\(Int(coordinator.gap)) px").monospacedDigit().frame(width: 42, alignment: .trailing)
            }

            if !coordinator.groups.isEmpty {
                Divider()
                Text("Window groups").font(.subheadline.weight(.semibold))
                ForEach(coordinator.groups) { group in
                    HStack(spacing: 8) {
                        Circle()
                            .fill(GroupPalette.color(at: group.colorIndex))
                            .frame(width: 10, height: 10)
                        Button {
                            _ = coordinator.activateGroup(group.id)
                        } label: {
                            HStack {
                                Text(group.name)
                                Spacer()
                                Text("\(group.windows.count)")
                                    .monospacedDigit().foregroundStyle(.secondary)
                            }
                        }
                        .buttonStyle(.plain)
                        Button {
                            coordinator.deleteGroup(group.id)
                        } label: {
                            Image(systemName: "xmark")
                        }
                        .buttonStyle(ElegantIconButtonStyle(destructive: true, size: 26))
                    }
                }
            }

            DisclosureGroup("Choose from a list instead", isExpanded: $showWindowList) {
                VStack(alignment: .leading, spacing: 6) {
                    ScrollView {
                        LazyVStack(alignment: .leading, spacing: 4) {
                            ForEach(coordinator.windows) { window in
                                Toggle(isOn: Binding(
                                    get: { coordinator.windows.first(where: { $0.id == window.id })?.isSelected ?? false },
                                    set: { _ in coordinator.toggleSelection(window.id) }
                                )) {
                                    VStack(alignment: .leading, spacing: 1) {
                                        Text(window.title).lineLimit(1)
                                        Text(window.appName).font(.caption).foregroundStyle(.secondary)
                                    }
                                }
                                .toggleStyle(.checkbox)
                            }
                        }
                    }
                    .frame(maxHeight: 170)
                    Button { coordinator.arrangeEqualColumns() } label: {
                        Label("Arrange selected equally", systemImage: "rectangle.split.3x1")
                    }
                        .buttonStyle(ElegantButtonStyle(kind: .primary))
                        .disabled(coordinator.selectedWindows.count < 2)
                }
            }

            if !store.layouts(for: coordinator.selectedDisplayID).isEmpty {
                Divider()
                Text("Saved for this display").font(.subheadline.weight(.semibold))
                ForEach(store.layouts(for: coordinator.selectedDisplayID)) { layout in
                    Button(layout.name) { coordinator.applySavedLayout(layout) }
                        .buttonStyle(ElegantButtonStyle(kind: .secondary))
                }
            }

            HStack {
                TextField("Layout name", text: $saveName)
                Button("Save") { saveLayout() }
                    .buttonStyle(ElegantButtonStyle(kind: .primary, minWidth: 72))
                    .disabled(coordinator.selectedWindows.count < 2)
            }

            Divider()
            HStack {
                Button("Settings…") {
                    SettingsWindow.open(model: model)
                    NSApp.activate(ignoringOtherApps: true)
                }
                .buttonStyle(ElegantButtonStyle(kind: .secondary))
                Spacer()
                Button("Quit") { NSApplication.shared.terminate(nil) }
                    .buttonStyle(ElegantButtonStyle(kind: .destructive))
            }
        }
        .padding(14)
    }

    private func saveLayout() {
        let name = saveName.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let layout = coordinator.makeSavedLayout(name: name.isEmpty ? "Layout \(store.layouts.count + 1)" : name) else { return }
        store.upsert(layout)
        saveName = ""
    }
}

struct OnboardingView: View {
    @ObservedObject var coordinator: WindowCoordinator
    @State private var didOpenSettings = false
    private let permissionPoller = Timer.publish(every: 0.75, on: .main, in: .common).autoconnect()

    var body: some View {
        VStack(spacing: 18) {
            Image(systemName: "rectangle.split.3x1")
                .font(.system(size: 42, weight: .medium))
                .foregroundStyle(.tint)

            VStack(spacing: 7) {
                Text("Allow Window Control")
                    .font(.title2.bold())
                Text("Required to move and resize windows.")
                    .multilineTextAlignment(.center)
                    .foregroundStyle(.secondary)
            }

            Button {
                didOpenSettings = true
                coordinator.beginAccessibilitySetup()
            } label: {
                Label("Open System Settings", systemImage: "gear")
            }
            .buttonStyle(ElegantButtonStyle(kind: .primary, minWidth: 230))

            if didOpenSettings {
                VStack(spacing: 10) {
                    HStack(spacing: 8) {
                        ProgressView().controlSize(.small)
                        Text("Turn Window Columns on. This restarts by itself once you do.")
                    }
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)

                    // macOS answers "am I trusted?" from a cache fixed when the
                    // process launched, so a grant made just now can only be
                    // picked up by a new process. The app notices and restarts
                    // on its own; this is the manual path if it does not.
                    Button("Quit & Reopen") {
                        coordinator.relaunchForAccessibility()
                    }
                    .buttonStyle(ElegantButtonStyle(kind: .secondary, minWidth: 160))
                }
            }

            if coordinator.permissionResetsOnEveryBuild {
                // Without this, being asked again after every rebuild looks like
                // the grant is simply being ignored.
                VStack(spacing: 3) {
                    Text("This build is signed ad-hoc")
                        .font(.caption.weight(.semibold))
                    Text("macOS ties the permission to the exact binary, so every rebuild asks again. Run `make signing-identity` once to grant it permanently.")
                        .font(.caption2)
                        .multilineTextAlignment(.center)
                }
                .foregroundStyle(.secondary)
                .padding(10)
                .background(Color(nsColor: .controlBackgroundColor), in: RoundedRectangle(cornerRadius: 9))
            }
        }
        .frame(width: 350)
        .padding(28)
        .background(Color(nsColor: .windowBackgroundColor), in: RoundedRectangle(cornerRadius: 18))
        .onReceive(permissionPoller) { _ in coordinator.pollAccessibilityState() }
    }
}

private struct ShortcutRow: View {
    let title: String
    let caption: String?
    let placeholder: String
    @Binding var binding: ShortcutBinding?

    var body: some View {
        HStack(alignment: .firstTextBaseline) {
            VStack(alignment: .leading, spacing: 2) {
                Text(title)
                if let caption {
                    Text(caption).font(.caption).foregroundStyle(.secondary)
                }
            }
            Spacer()
            ShortcutRecorder(placeholder: placeholder, binding: $binding)
                .frame(width: 132, height: 26)
        }
    }
}

/// The modifier set shared by the numbered column shortcuts. Recording a full
/// shortcut makes no sense here — the key is always 2 through 9.
private struct ModifierPicker: View {
    @Binding var flags: NSEvent.ModifierFlags

    private static let options: [(NSEvent.ModifierFlags, String)] = [
        (.control, "⌃"), (.option, "⌥"), (.shift, "⇧"), (.command, "⌘")
    ]

    var body: some View {
        HStack(spacing: 6) {
            ForEach(Array(Self.options.enumerated()), id: \.offset) { _, option in
                let (flag, symbol) = option
                Toggle(symbol, isOn: Binding(
                    get: { flags.contains(flag) },
                    set: { isOn in
                        var updated = flags
                        if isOn { updated.insert(flag) } else { updated.remove(flag) }
                        // A bare number key as a global shortcut would swallow
                        // typing everywhere, so never allow an empty set.
                        if updated.isEmpty { return }
                        flags = updated
                    }
                ))
                .toggleStyle(.button)
            }
            Text(ShortcutFormatter.modifierSymbols(flags) + "2 … " + ShortcutFormatter.modifierSymbols(flags) + "9")
                .font(.caption.monospaced())
                .foregroundStyle(.secondary)
        }
    }
}

/// Hosts `SettingsView` in the standalone settings window.
struct SettingsWindowContent: View {
    @ObservedObject var model: AppModel

    var body: some View {
        SettingsView(model: model)
    }
}

struct SettingsView: View {
    @ObservedObject var model: AppModel
    @ObservedObject private var coordinator: WindowCoordinator
    @ObservedObject private var store: LayoutStore
    @State private var loginError: String?

    init(model: AppModel) {
        self.model = model
        coordinator = model.coordinator
        store = model.store
    }

    var body: some View {
        TabView {
            general.tabItem { Label("General", systemImage: "gearshape") }
            shortcuts.tabItem { Label("Shortcuts", systemImage: "command") }
            groups.tabItem { Label("Groups", systemImage: "rectangle.3.group") }
        }
        .frame(width: 520, height: 460)
        .alert("Couldn’t change login setting", isPresented: Binding(
            get: { loginError != nil }, set: { if !$0 { loginError = nil } }
        )) { Button("OK") { loginError = nil } } message: { Text(loginError ?? "") }
    }

    // MARK: - General

    private var general: some View {
        Form {
            Section {
                Toggle("Launch at login", isOn: Binding(
                    get: { store.preferences.launchAtLogin },
                    set: { enabled in
                        do { try model.setLaunchAtLogin(enabled) }
                        catch { loginError = error.localizedDescription }
                    }
                ))
                Picker("Appearance", selection: Binding(
                    get: { store.preferences.appearance },
                    set: { model.setAppearance($0) }
                )) {
                    ForEach(AppAppearance.allCases) { Text($0.label).tag($0) }
                }
                .pickerStyle(.segmented)
            }

            Section("Chooser") {
                Toggle("Show window previews", isOn: Binding(
                    get: { store.preferences.showWindowPreviews },
                    set: { store.preferences.showWindowPreviews = $0 }
                ))
                Text("Thumbnails need Screen Recording permission. With previews off the chooser shows application icons and is considerably denser.")
                    .font(.caption).foregroundStyle(.secondary)
            }

            Section("Layout") {
                LabeledContent("Gap between columns") {
                    HStack {
                        Slider(
                            value: Binding(get: { coordinator.gap }, set: { model.updateGap($0) }),
                            in: 0...32, step: 1
                        )
                        Text("\(Int(coordinator.gap)) pt")
                            .monospacedDigit().frame(width: 46, alignment: .trailing)
                    }
                }
            }

            if !coordinator.isTrusted {
                Section("Permission") {
                    Label("Accessibility access is off", systemImage: "exclamationmark.triangle.fill")
                        .foregroundStyle(.orange)
                    Button("Open Accessibility Settings") { coordinator.beginAccessibilitySetup() }
                }
            }
        }
        .formStyle(.grouped)
    }

    // MARK: - Shortcuts

    private var shortcuts: some View {
        Form {
            Section {
                ShortcutRow(
                    title: "Open the chooser",
                    caption: nil,
                    placeholder: "Not set",
                    binding: Binding(
                        get: { store.preferences.openChooserShortcut },
                        set: { store.preferences.openChooserShortcut = $0; model.reloadShortcuts() }
                    )
                )
                ShortcutRow(
                    title: "New group",
                    caption: nil,
                    placeholder: "Not set",
                    binding: Binding(
                        get: { store.preferences.createGroupShortcut },
                        set: { store.preferences.createGroupShortcut = $0; model.reloadShortcuts() }
                    )
                )
                ShortcutRow(
                    title: "Minimize the active group",
                    caption: "Click its Dock icon to bring it back.",
                    placeholder: "Not set",
                    binding: Binding(
                        get: { store.preferences.minimizeGroupShortcut },
                        set: { store.preferences.minimizeGroupShortcut = $0; model.reloadShortcuts() }
                    )
                )
                ShortcutRow(
                    title: "Undo arrangement",
                    caption: nil,
                    placeholder: "Not set",
                    binding: Binding(
                        get: { store.preferences.undoShortcut },
                        set: { store.preferences.undoShortcut = $0; model.reloadShortcuts() }
                    )
                )
            } header: {
                Text("Global shortcuts")
            } footer: {
                Text("Click a shortcut to record a new one. Escape cancels, Delete clears it.")
                    .font(.caption).foregroundStyle(.secondary)
            }

            Section {
                Picker("Double-tap to open New Group", selection: Binding(
                    get: { store.preferences.doubleTapModifier },
                    set: { store.preferences.doubleTapModifier = $0; model.reloadShortcuts() }
                )) {
                    ForEach(DoubleTapModifier.allCases) { Text($0.label).tag($0) }
                }
            } footer: {
                Text("Tap the chosen modifier twice quickly, holding nothing else.")
                    .font(.caption).foregroundStyle(.secondary)
            }

            Section {
                ModifierPicker(
                    flags: Binding(
                        get: { NSEvent.ModifierFlags(rawValue: store.preferences.columnModifierFlags) },
                        set: { store.preferences.columnModifierFlags = $0.rawValue; model.reloadShortcuts() }
                    )
                )
            } header: {
                Text("Column shortcuts")
            } footer: {
                Text("These modifiers plus 2 through 9 arrange that many of the frontmost windows.")
                    .font(.caption).foregroundStyle(.secondary)
            }

            if !model.rejectedShortcuts.isEmpty {
                Section {
                    ForEach(model.rejectedShortcuts, id: \.self) { name in
                        Label(name, systemImage: "exclamationmark.triangle.fill")
                            .font(.callout)
                            .foregroundStyle(.orange)
                    }
                } header: {
                    Text("Unavailable")
                } footer: {
                    Text("macOS or another application already owns these combinations. Record different ones.")
                        .font(.caption).foregroundStyle(.secondary)
                }
            }
        }
        .formStyle(.grouped)
    }

    // MARK: - Groups

    private var groups: some View {
        Form {
            Section("Active groups") {
                if coordinator.groups.isEmpty {
                    Text("No groups yet. Select two or more windows in the chooser to make one.")
                        .foregroundStyle(.secondary)
                }
                ForEach(coordinator.groups) { group in
                    HStack(spacing: 10) {
                        Circle()
                            .fill(GroupPalette.color(at: group.colorIndex))
                            .frame(width: 11, height: 11)
                        VStack(alignment: .leading, spacing: 1) {
                            Text(group.name)
                            Text("\(group.windows.count) windows · Command-Tab slot \(group.slot + 1)")
                                .font(.caption).foregroundStyle(.secondary)
                        }
                        Spacer()
                        Button("Show") { _ = coordinator.activateGroup(group.id) }
                        Button(role: .destructive) { coordinator.deleteGroup(group.id) } label: {
                            Image(systemName: "trash")
                        }
                    }
                }
            }

            if !store.layouts.isEmpty {
                Section("Saved layouts") {
                    ForEach(store.layouts) { layout in
                        HStack {
                            VStack(alignment: .leading, spacing: 1) {
                                Text(layout.name)
                                Text("\(layout.windows.count) windows · \(Int(layout.gap)) pt gap")
                                    .font(.caption).foregroundStyle(.secondary)
                            }
                            Spacer()
                            Button(role: .destructive) { store.delete(layout) } label: {
                                Image(systemName: "trash")
                            }
                        }
                    }
                }
            }

            if !coordinator.unsupportedWindows.isEmpty {
                Section {
                    ForEach(coordinator.unsupportedWindows, id: \.self) {
                        Text($0).font(.caption)
                    }
                } header: {
                    Text("Cannot be arranged")
                } footer: {
                    Text("These windows do not expose movable and resizable Accessibility attributes.")
                        .font(.caption).foregroundStyle(.secondary)
                }
            }
        }
        .formStyle(.grouped)
    }
}
