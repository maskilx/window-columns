import AppKit
import SwiftUI

/// Carries a freshly captured thumbnail back from the capture task.
///
/// `NSImage` only conforms to `Sendable` on macOS 14, and this app supports 13.
/// The image is constructed inside the task and handed over without being kept
/// or touched anywhere else, so the transfer is safe even though the compiler
/// cannot prove it on the older target.
private struct CapturedPreview: @unchecked Sendable {
    let image: NSImage
}

final class KeyablePanel: NSPanel {
    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { true }
}

@MainActor
final class WindowSwitcherModel: ObservableObject {
    struct Option: Identifiable {
        let id: UUID
        let title: String
        let appName: String
        let icon: NSImage
        let fingerprint: WindowFingerprint
        let groupID: UUID?
        let groupName: String?
        let groupColorIndex: Int?
        let isMinimized: Bool
        /// Narrowest this window will go. Some refuse to share the display.
        let minimumWidth: CGFloat
    }

    /// The arrangement a selection would produce, in physical order.
    struct ColumnPlan: Equatable {
        struct Column: Equatable, Identifiable {
            let id: UUID
            /// 1 is the rightmost column.
            let position: Int
            let widthFraction: CGFloat
            let points: Int
        }
        var columns: [Column]
        var gapFraction: CGFloat
        var gapPoints: Int
        var displayName: String
    }

    @Published private(set) var options: [Option] = []
    @Published private(set) var layoutPlan: ColumnPlan?
    @Published private(set) var errorMessage: String?
    @Published var filterText = "" { didSet { clampFocus() } }
    /// True only while the user has deliberately clicked into a group's name.
    @Published var isRenamingGroup = false
    @Published private(set) var activeGroupID: UUID?
    /// Usable width of the display the arrangement will land on.
    @Published private(set) var displayWidth: CGFloat = 0
    /// Thumbnails arrive after the chooser is already on screen.
    @Published private(set) var previews: [UUID: NSImage] = [:]
    private var previewTask: Task<Void, Never>?
    @Published private(set) var selectedIDs: [UUID] = [] { didSet { rebuildLayoutPlan() } }
    @Published var focusedIndex = 0
    @Published private(set) var hasExistingGroup = false
    @Published private(set) var groups: [WindowGroupSnapshot] = []
    @Published private(set) var isCreatingNewGroup = false
    @Published private(set) var editingGroupID: UUID?
    @Published var showWindowPreviews: Bool
    @Published private(set) var canShowWindowPreviews = false

    private let coordinator: WindowCoordinator
    private let store: LayoutStore
    private let appModel: AppModel
    var dismiss: (() -> Void)?
    var openSettings: (() -> Void)?

    var appearance: AppAppearance { store.preferences.appearance }
    func setAppearance(_ value: AppAppearance) {
        appModel.setAppearance(value)
        objectWillChange.send()
    }

    /// The group currently being edited, if any.
    var editingGroup: WindowGroupSnapshot? {
        groups.first { $0.id == editingGroupID }
    }

    func isMember(_ id: UUID) -> Bool { selectedIDs.contains(id) }

    init(appModel: AppModel) {
        self.appModel = appModel
        self.coordinator = appModel.coordinator
        self.store = appModel.store
        showWindowPreviews = appModel.store.preferences.showWindowPreviews
    }

    /// - Parameter rescanWindows: pass `false` when the live window list is
    ///   already current. A full Accessibility scan costs several round trips per
    ///   window on the system and is the slowest thing the chooser does.
    func reload(createNewGroup: Bool = false, rescanWindows: Bool = true) {
        if rescanWindows { coordinator.refresh() }
        groups = coordinator.groups
        canShowWindowPreviews = coordinator.canShowWindowPreviews
        isCreatingNewGroup = createNewGroup
        // Opening the chooser starts a clean selection. Editing an existing
        // group is always explicit via its chip at the top of the chooser.
        editingGroupID = nil
        options = coordinator.windows.map { window in
            let icon = NSRunningApplication(processIdentifier: window.pid)?.icon
                ?? NSImage(systemSymbolName: "macwindow", accessibilityDescription: nil)
                ?? NSImage()
            let group = coordinator.group(containing: window)
            return Option(
                id: window.id,
                title: window.title,
                appName: window.appName,
                icon: icon,
                fingerprint: window.fingerprint,
                groupID: group?.id,
                groupName: group?.name,
                groupColorIndex: group?.colorIndex,
                isMinimized: window.isMinimized,
                minimumWidth: window.minimumSize.width
            )
        }
        // The chooser numbers slots from right to left; the layout engine stores
        // physical columns from left to right, so presentation order is reversed.
        selectedIDs = []
        hasExistingGroup = false
        focusedIndex = 0
        filterText = ""
        errorMessage = nil
        activeGroupID = coordinator.activeGroupID
        displayWidth = coordinator.selectedDisplay?.visibleFrame.width ?? 0
        loadPreviews()
    }

    /// Captures thumbnails off the main thread and publishes them as they land.
    ///
    /// These used to be captured inline while building `options`, so opening the
    /// chooser blocked on a window capture plus a downsample for every window on
    /// the system before anything could be drawn.
    private func loadPreviews() {
        previewTask?.cancel()
        previews = [:]
        guard showWindowPreviews, canShowWindowPreviews else { return }
        let source = coordinator.previewSource
        let targets: [(id: UUID, number: CGWindowID)] = options.compactMap { option in
            option.fingerprint.windowNumber.map { (option.id, CGWindowID($0)) }
        }
        guard !targets.isEmpty else { return }
        previewTask = Task { [weak self] in
            for target in targets {
                if Task.isCancelled { return }
                let captured = await Task.detached(priority: .userInitiated) { () -> CapturedPreview? in
                    source.previewImage(forWindowID: target.number).map(CapturedPreview.init)
                }.value
                if Task.isCancelled { return }
                guard let captured, let self else { continue }
                self.previews[target.id] = captured.image
            }
        }
    }

    /// Windows matching the current filter, in the order they are shown.
    var visibleOptions: [Option] {
        guard !filterText.isEmpty else { return options }
        let needle = filterText.lowercased()
        return options.filter {
            $0.title.lowercased().contains(needle) || $0.appName.lowercased().contains(needle)
        }
    }

    @discardableResult
    func clearFilter() -> Bool {
        guard !filterText.isEmpty else { return false }
        filterText = ""
        return true
    }

    private func clampFocus() {
        focusedIndex = min(max(focusedIndex, 0), max(0, visibleOptions.count - 1))
    }

    private func rebuildLayoutPlan() {
        errorMessage = nil
        let physical = Array(selectedIDs.reversed())
        guard physical.count >= 2,
              let result = coordinator.previewLayout(forOrder: physical),
              result.display.width > 0 else {
            layoutPlan = nil
            return
        }
        let total = result.display.width
        let columns = zip(physical.indices, result.frames).map { index, frame in
            ColumnPlan.Column(
                id: physical[index],
                position: physical.count - index,
                widthFraction: frame.width / total,
                points: Int(frame.width.rounded())
            )
        }
        layoutPlan = ColumnPlan(
            columns: columns,
            gapFraction: CGFloat(coordinator.gap) / total,
            gapPoints: Int(coordinator.gap.rounded()),
            displayName: coordinator.selectedDisplay?.name ?? ""
        )
    }

    func toggle(_ id: UUID) {
        if let index = selectedIDs.firstIndex(of: id) {
            selectedIDs.remove(at: index)
            return
        }
        // Refuse a selection that cannot be tiled instead of accepting it and
        // failing later with windows already half-moved.
        let candidate = selectedIDs + [id]
        if candidate.count >= 2, let message = coordinator.fitFailureMessage(forSelection: candidate) {
            errorMessage = message
            return
        }
        selectedIDs.append(id)
    }

    /// True when this window alone cannot share the display evenly.
    func isTooWideToShare(_ option: Option) -> Bool {
        displayWidth > 0 && option.minimumWidth > displayWidth / 2
    }

    func toggleFocused() {
        let visible = visibleOptions
        guard visible.indices.contains(focusedIndex) else { return }
        toggle(visible[focusedIndex].id)
    }

    func moveSelection(_ id: UUID, by offset: Int) {
        guard let oldIndex = selectedIDs.firstIndex(of: id) else { return }
        let newIndex = min(max(oldIndex + offset, 0), selectedIDs.count - 1)
        guard newIndex != oldIndex else { return }
        selectedIDs.remove(at: oldIndex)
        selectedIDs.insert(id, at: newIndex)
    }

    func detach(_ id: UUID) {
        // The x on an order chip edits the pending selection only. Mutating the
        // live group before Return made Cancel destructive and caused surprising
        // group changes from a single click.
        selectedIDs.removeAll { $0 == id }
    }

    func detachAll() {
        coordinator.detachAllWindows()
        selectedIDs = []
        hasExistingGroup = false
        dismiss?()
    }

    func activateGroup(_ id: UUID) {
        if coordinator.activateGroup(id) { dismiss?() }
    }

    func editGroup(_ id: UUID) {
        guard let group = groups.first(where: { $0.id == id }) else { return }
        isCreatingNewGroup = false
        editingGroupID = id
        var remainingIDs = Set(options.map(\.id))
        var matchedIDs: [UUID] = []
        for fingerprint in group.windows {
            let exact = options.first {
                guard remainingIDs.contains($0.id),
                      $0.fingerprint.bundleIdentifier == fingerprint.bundleIdentifier else { return false }
                if let number = fingerprint.windowNumber {
                    return $0.fingerprint.windowNumber == number
                }
                return $0.fingerprint.title == fingerprint.title
            }
            if let id = exact?.id {
                matchedIDs.append(id)
                remainingIDs.remove(id)
            }
        }
        selectedIDs = Array(matchedIDs.reversed())
        hasExistingGroup = true
    }

    func moveWindow(_ windowID: UUID, to groupID: UUID) {
        guard coordinator.moveWindow(windowID, toGroup: groupID) else { return }
        reload(createNewGroup: false, rescanWindows: false)
        editGroup(groupID)
    }

    func setShowWindowPreviews(_ enabled: Bool) {
        let editedGroup = editingGroupID
        showWindowPreviews = enabled
        appModel.setShowWindowPreviews(enabled)
        reload(createNewGroup: isCreatingNewGroup, rescanWindows: false)
        if let editedGroup { editGroup(editedGroup) }
    }

    func requestPreviewPermission() {
        _ = coordinator.requestWindowPreviewPermission()
        canShowWindowPreviews = coordinator.canShowWindowPreviews
        if canShowWindowPreviews {
            reload(createNewGroup: isCreatingNewGroup, rescanWindows: false)
        }
    }

    func unload() {
        // Full-window previews are the largest transient allocation in the app.
        // Release them as soon as the chooser closes.
        previewTask?.cancel()
        previewTask = nil
        previews = [:]
        options = []
        selectedIDs = []
        groups = []
        focusedIndex = 0
        filterText = ""
        errorMessage = nil
        layoutPlan = nil
        editingGroupID = nil
        hasExistingGroup = false
    }

    func rename(_ id: UUID, to name: String) {
        coordinator.renameGroup(id, to: name)
        groups = coordinator.groups
    }

    func deleteGroup(_ id: UUID) {
        coordinator.deleteGroup(id)
        groups = coordinator.groups
        if editingGroupID == id {
            editingGroupID = nil
            selectedIDs = []
            hasExistingGroup = false
        }
    }

    var selectedOptions: [Option] {
        selectedIDs.compactMap { id in options.first { $0.id == id } }
    }

    func moveFocus(horizontal: Int = 0, vertical: Int = 0, columns: Int) {
        let visible = visibleOptions
        guard !visible.isEmpty else { return }
        let delta = horizontal + vertical * max(1, columns)
        focusedIndex = min(max(focusedIndex + delta, 0), visible.count - 1)
    }

    func submit() {
        guard selectedIDs.count >= 2 else { return }
        let succeeded: Bool
        if let editingGroupID {
            succeeded = coordinator.updateGroup(editingGroupID, inOrder: Array(selectedIDs.reversed()))
        } else {
            succeeded = coordinator.createGroup(inOrder: Array(selectedIDs.reversed())) != nil
        }
        if succeeded {
            dismiss?()
        } else {
            // This used to fail silently: the error only ever reached an alert
            // in Settings, which is not open when the chooser is.
            errorMessage = coordinator.lastError?.errorDescription
                ?? "Those windows could not be arranged."
        }
    }
}

/// Panel size and grid shape, resolved in one place.
///
/// The column count used to be hardcoded to 3 in the grid and hardcoded a second
/// time in the arrow-key handler; the two agreed only by coincidence, so any
/// change to the grid silently broke keyboard navigation. Everything derives
/// from these numbers now.
struct ChooserMetrics {
    static let cardSpacing: CGFloat = 12
    static let padding: CGFloat = 22

    let columnCount: Int
    let width: CGFloat
    let height: CGFloat

    static func cardSize(previews: Bool) -> CGSize {
        previews ? CGSize(width: 258, height: 268) : CGSize(width: 168, height: 128)
    }

    /// - Parameter reservesPreview: whether a layout preview strip will be on
    ///   screen the moment the chooser opens. Reserving its height for a fresh,
    ///   empty selection left a band of dead space under the grid.
    static func resolve(
        optionCount: Int,
        hasGroups: Bool,
        previews: Bool,
        reservesPreview: Bool,
        on screen: NSScreen?
    ) -> ChooserMetrics {
        let available = screen?.visibleFrame.size ?? CGSize(width: 1280, height: 800)
        let maxWidth = min(available.width - 80, 1240)
        let maxHeight = min(available.height - 80, 860)
        let card = cardSize(previews: previews)
        let count = max(optionCount, 1)

        let chrome = padding * 2
        let widest = max(1, Int((maxWidth - chrome + cardSpacing) / (card.width + cardSpacing)))
        // Aim for a roughly landscape block rather than one long row: eight
        // windows in a single row of eight is as awkward as eight in a column.
        let balanced = max(1, Int(ceil((Double(count) * 1.7).squareRoot())))
        let columnCount = max(1, min(widest, count, balanced))
        let width = min(maxWidth, chrome + CGFloat(columnCount) * card.width
            + CGFloat(columnCount - 1) * cardSpacing)

        let rows = max(1, Int(ceil(Double(count) / Double(columnCount))))
        let gridHeight = CGFloat(rows) * card.height + CGFloat(rows - 1) * cardSpacing
        // shelf + header + optional layout preview + footer + the stack's spacing
        let fixed: CGFloat = (hasGroups ? 74 : 0) + 62 + (reservesPreview ? 84 : 0)
            + 46 + chrome + (hasGroups ? 48 : 32)
        let height = min(maxHeight, max(300, fixed + gridHeight))
        return ChooserMetrics(columnCount: columnCount, width: width, height: height)
    }
}

struct WindowSwitcherView: View {
    @ObservedObject var model: WindowSwitcherModel
    let metrics: ChooserMetrics
    let onCancel: () -> Void
    /// Ends any in-progress rename so the keyboard returns to the filter.
    let onFocusFilter: () -> Void

    private var headline: String {
        if let editing = model.editingGroup { return "Editing \(editing.name)" }
        return model.isCreatingNewGroup ? "Create a window group" : "Choose windows"
    }

    private var guidance: String {
        if model.editingGroup != nil {
            return "Click a window to add or remove it, then press Return to apply"
        }
        return model.isCreatingNewGroup
            ? "Choose two or more windows. This group gets its own Command-Tab icon."
            : "Click windows in order — the strip below shows where each one lands"
    }

    private var columns: [GridItem] {
        Array(
            repeating: GridItem(.flexible(), spacing: ChooserMetrics.cardSpacing),
            count: metrics.columnCount
        )
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            if !model.groups.isEmpty {
                GroupShelf(model: model)
            }

            HStack {
                VStack(alignment: .leading, spacing: 3) {
                    Text(headline)
                        .font(.title2.bold())
                    Text(guidance)
                        .foregroundStyle(.secondary)
                }
                Spacer()
                if model.showWindowPreviews && !model.canShowWindowPreviews {
                    Button("Allow Previews") {
                        model.requestPreviewPermission()
                    }
                    .buttonStyle(ElegantButtonStyle(kind: .secondary, minWidth: 110))
                    .help("Window thumbnails need optional Screen Recording access")
                }
                ChooserSearchField(text: Binding(
                    get: { model.filterText },
                    set: { model.filterText = $0 }
                ))
                .frame(width: 200)
                ChooserSettingsMenu(model: model)
            }

            if model.layoutPlan != nil {
                LayoutPreviewStrip(model: model)
            }

            if model.visibleOptions.isEmpty {
                VStack(spacing: 10) {
                    Image(systemName: model.filterText.isEmpty ? "macwindow.badge.xmark" : "magnifyingglass")
                        .font(.system(size: 38))
                    Text(model.filterText.isEmpty ? "No supported windows" : "No windows match “\(model.filterText)”")
                        .font(.headline)
                    Text(model.filterText.isEmpty
                         ? "Open some resizable windows and try again."
                         : "Press Escape to clear the filter.")
                        .foregroundStyle(.secondary)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                ScrollView {
                    LazyVGrid(columns: columns, spacing: 12) {
                        ForEach(Array(model.visibleOptions.enumerated()), id: \.element.id) { index, option in
                            WindowOptionCard(
                                option: option,
                                preview: model.previews[option.id],
                                canCapture: model.canShowWindowPreviews,
                                selectionNumber: model.selectedIDs.firstIndex(of: option.id).map { $0 + 1 },
                                isFocused: model.focusedIndex == index,
                                previewsEnabled: model.showWindowPreviews,
                                tooWideToShare: model.isTooWideToShare(option)
                            )
                            .overlay(alignment: .topLeading) {
                                if model.editingGroup != nil {
                                    Label(
                                        model.isMember(option.id) ? "In group" : "Add",
                                        systemImage: model.isMember(option.id) ? "checkmark.circle.fill" : "plus.circle"
                                    )
                                    .font(.caption2.weight(.semibold))
                                    .labelStyle(.titleAndIcon)
                                    .padding(.horizontal, 7).padding(.vertical, 3)
                                    .background(.regularMaterial, in: Capsule())
                                    .foregroundStyle(model.isMember(option.id) ? Color.accentColor : .secondary)
                                    .padding(8)
                                }
                            }
                            .contentShape(Rectangle())
                            .onTapGesture {
                                model.focusedIndex = index
                                model.toggle(option.id)
                            }
                            .draggable(option.id.uuidString)
                        }
                    }
                    .padding(2)
                }
            }

            HStack {
                if let errorMessage = model.errorMessage {
                    Label(errorMessage, systemImage: "exclamationmark.triangle.fill")
                        .font(.caption)
                        .foregroundStyle(.red)
                        .lineLimit(2)
                } else {
                    Text("Type to search · ↑↓←→ move · Return adds or removes · ⌘Return arranges")
                        .font(.caption).foregroundStyle(.secondary)
                }
                Spacer()
                if model.hasExistingGroup && !model.isCreatingNewGroup {
                    Button(role: .destructive) { model.detachAll() } label: {
                        Label("Detach All", systemImage: "rectangle.portrait.and.arrow.right")
                    }
                    .buttonStyle(ElegantButtonStyle(kind: .destructive))
                }
                Button("Cancel", action: onCancel)
                    .buttonStyle(ElegantButtonStyle(kind: .secondary, minWidth: 84))
                    .keyboardShortcut(.cancelAction)
                Button { model.submit() } label: {
                    Label(
                        model.selectedIDs.count >= 2
                            ? "\(model.hasExistingGroup ? "Update" : "Create") Group · \(model.selectedIDs.count)"
                            : (model.hasExistingGroup ? "Update Group" : "Create Group"),
                        systemImage: model.hasExistingGroup ? "checkmark.rectangle.stack" : "plus.rectangle.on.rectangle"
                    )
                }
                    .buttonStyle(ElegantButtonStyle(kind: .primary, minWidth: 200))
                    .disabled(model.selectedIDs.count < 2)
            }
        }
        .padding(ChooserMetrics.padding)
        .frame(width: metrics.width, height: metrics.height)
        .background(Color(nsColor: .windowBackgroundColor), in: RoundedRectangle(cornerRadius: 24, style: .continuous))
        .overlay {
            RoundedRectangle(cornerRadius: 24, style: .continuous)
                .stroke(Color(nsColor: .separatorColor), lineWidth: 1)
        }
    }
}

/// A proportional picture of the arrangement the current selection produces.
///
/// This replaced a horizontal strip of chips that repeated the numbers already
/// stamped on the cards and spelled position out in words ("Rightmost",
/// "1 slot left"). Showing the real columns at their real widths answers the
/// question the strip was trying to describe, and makes it self-evident that
/// position 1 is the rightmost column.
private struct LayoutPreviewStrip: View {
    @ObservedObject var model: WindowSwitcherModel

    var body: some View {
        if let plan = model.layoutPlan {
            VStack(alignment: .leading, spacing: 6) {
                GeometryReader { geometry in
                    let width = geometry.size.width - 8
                    HStack(spacing: 0) {
                        ForEach(Array(plan.columns.enumerated()), id: \.element.id) { index, column in
                            columnView(column, width: max(1, width * column.widthFraction))
                            if index < plan.columns.count - 1 {
                                Color.clear.frame(width: max(1, width * plan.gapFraction))
                            }
                        }
                    }
                    .padding(4)
                    .frame(width: geometry.size.width, height: 58, alignment: .leading)
                    .background(
                        RoundedRectangle(cornerRadius: 9, style: .continuous)
                            .fill(Color(nsColor: .underPageBackgroundColor))
                    )
                    .overlay {
                        RoundedRectangle(cornerRadius: 9, style: .continuous)
                            .strokeBorder(Color(nsColor: .separatorColor))
                    }
                }
                .frame(height: 58)

                Text(caption(for: plan))
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            }
        }
    }

    private func caption(for plan: WindowSwitcherModel.ColumnPlan) -> String {
        let display = plan.displayName.isEmpty ? "this display" : plan.displayName
        return "Result on \(display) · \(plan.gapPoints) pt gap · position 1 is the rightmost column"
    }

    @ViewBuilder
    private func columnView(_ column: WindowSwitcherModel.ColumnPlan.Column, width: CGFloat) -> some View {
        let option = model.options.first { $0.id == column.id }
        VStack(spacing: 2) {
            HStack(spacing: 4) {
                Text("\(column.position)")
                    .font(.system(size: 10, weight: .bold))
                    .foregroundStyle(.white)
                    .frame(width: 17, height: 17)
                    .background(Color.accentColor, in: Circle())
                if let option, width > 58 {
                    Image(nsImage: option.icon)
                        .resizable().scaledToFit()
                        .frame(width: 16, height: 16)
                }
            }
            if width > 44 {
                Text("\(column.points) pt")
                    .font(.system(size: 9).monospacedDigit())
                    .foregroundStyle(.secondary)
            }
        }
        .frame(width: width, height: 50)
        .background(
            RoundedRectangle(cornerRadius: 5, style: .continuous)
                .fill(Color(nsColor: .controlBackgroundColor))
        )
        .overlay {
            RoundedRectangle(cornerRadius: 5, style: .continuous)
                .strokeBorder(Color(nsColor: .separatorColor))
        }
        .overlay(alignment: .topTrailing) {
            if width > 74 {
                Button { model.detach(column.id) } label: {
                    Image(systemName: "xmark")
                        .font(.system(size: 7, weight: .bold))
                }
                .buttonStyle(.plain)
                .foregroundStyle(.secondary)
                .padding(3)
                .help("Remove \(option?.title ?? "this window") from the arrangement")
            }
        }
        .help(option.map { "\($0.title) — \($0.appName)" } ?? "")
    }
}

/// The gear in the chooser header: appearance, previews, and a way through to
/// the full settings without leaving the keyboard-driven flow.
private struct ChooserSettingsMenu: View {
    @ObservedObject var model: WindowSwitcherModel

    var body: some View {
        Menu {
            Picker("Appearance", selection: Binding(
                get: { model.appearance },
                set: { model.setAppearance($0) }
            )) {
                ForEach(AppAppearance.allCases) { option in
                    Label(option.label, systemImage: option.symbol).tag(option)
                }
            }
            .pickerStyle(.inline)

            Divider()

            Toggle("Window previews", isOn: Binding(
                get: { model.showWindowPreviews },
                set: { model.setShowWindowPreviews($0) }
            ))

            Divider()

            Button("Shortcuts & Settings…") { model.openSettings?() }
        } label: {
            Image(systemName: "gearshape")
                .font(.system(size: 13, weight: .medium))
        }
        .menuStyle(.borderlessButton)
        .menuIndicator(.hidden)
        .frame(width: 30)
        .help("Appearance, previews, shortcuts, and settings")
    }
}

/// The chooser's search field — a real `NSSearchField`, focused on open.
///
/// Earlier versions drew something that looked like a field but was not one, so
/// clicking it did nothing and it never felt like a place you could type. The
/// reason for the imitation was that a focusable field competes with the
/// chooser for the arrow keys and Return; that is solved by intercepting only
/// those keys and letting everything else — including Space — reach the field
/// normally.
struct ChooserSearchField: NSViewRepresentable {
    @Binding var text: String

    func makeNSView(context: Context) -> NSSearchField {
        let field = NSSearchField()
        field.placeholderString = "Search windows"
        field.delegate = context.coordinator
        field.focusRingType = .default
        field.sendsSearchStringImmediately = true
        field.sendsWholeSearchString = false
        (field.cell as? NSSearchFieldCell)?.cancelButtonCell?.target = context.coordinator
        return field
    }

    func updateNSView(_ nsView: NSSearchField, context: Context) {
        context.coordinator.text = $text
        if nsView.stringValue != text { nsView.stringValue = text }
    }

    func makeCoordinator() -> Coordinator { Coordinator(text: $text) }

    final class Coordinator: NSObject, NSSearchFieldDelegate {
        var text: Binding<String>
        init(text: Binding<String>) { self.text = text }

        func controlTextDidChange(_ notification: Notification) {
            guard let field = notification.object as? NSSearchField else { return }
            text.wrappedValue = field.stringValue
        }
    }
}

private struct GroupShelf: View {
    @ObservedObject var model: WindowSwitcherModel

    var body: some View {
        VStack(alignment: .leading, spacing: 7) {
            Label("Your groups", systemImage: "rectangle.3.group")
                .font(.caption.weight(.semibold))
                .foregroundStyle(.secondary)
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 9) {
                    ForEach(model.groups) { group in
                        HStack(spacing: 8) {
                            Button {
                                model.editGroup(group.id)
                            } label: {
                                HStack(spacing: 8) {
                                    HStack(spacing: 3) {
                                        ForEach(Array(memberOptions(for: group).prefix(4))) { option in
                                            Image(nsImage: option.icon)
                                                .resizable()
                                                .scaledToFit()
                                                .frame(width: 24, height: 24)
                                                .padding(2)
                                                .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 6))
                                        }
                                    }
                                }
                            }
                            .buttonStyle(.plain)
                            .help("Edit \(group.name)")
                            GroupNameField(model: model, group: group)
                            Button {
                                model.activateGroup(group.id)
                            } label: {
                                Image(systemName: "arrow.up.forward.app")
                            }
                            .buttonStyle(ElegantIconButtonStyle(size: 28))
                            .help("Show \(group.name)")
                            Button {
                                model.deleteGroup(group.id)
                            } label: {
                                Image(systemName: "xmark")
                            }
                            .buttonStyle(ElegantIconButtonStyle(destructive: true, size: 28))
                            .help("Delete \(group.name)")
                        }
                        .padding(.leading, 10)
                        .padding(.trailing, 6)
                        .frame(height: 48)
                        .background(
                            GroupPalette.color(at: group.colorIndex).opacity(0.12),
                            in: RoundedRectangle(cornerRadius: 14, style: .continuous)
                        )
                        .overlay {
                            RoundedRectangle(cornerRadius: 14, style: .continuous)
                                .strokeBorder(
                                    GroupPalette.color(at: group.colorIndex)
                                        .opacity(model.activeGroupID == group.id ? 1 : 0.36),
                                    lineWidth: model.activeGroupID == group.id ? 2 : 1
                                )
                        }
                        .dropDestination(for: String.self) { values, _ in
                            guard let value = values.first, let id = UUID(uuidString: value) else { return false }
                            model.moveWindow(id, to: group.id)
                            return true
                        }
                    }
                }
            }
            .frame(height: 50)
        }
    }

    private func memberOptions(for group: WindowGroupSnapshot) -> [WindowSwitcherModel.Option] {
        model.options.filter { $0.groupID == group.id }
    }
}

/// The group's name — a label until you ask to rename it.
///
/// It used to be a live `TextField`. As the only focusable text control in the
/// panel, AppKit handed it first responder the moment the chooser opened, so
/// every keystroke went into the group name and type-to-filter never received
/// anything. Keeping the field out of the view tree until it is wanted removes
/// the competition for the keyboard rather than racing it.
private struct GroupNameField: View {
    @ObservedObject var model: WindowSwitcherModel
    let group: WindowGroupSnapshot
    @State private var draft = ""
    @State private var isEditing = false
    @FocusState private var isFocused: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 1) {
            if isEditing {
                TextField("Group \(group.slot + 1)", text: $draft)
                    .textFieldStyle(.plain)
                    .font(.subheadline.weight(.semibold))
                    .frame(width: 104)
                    .focused($isFocused)
                    .onSubmit { finish() }
                    .onChange(of: isFocused) { focused in
                        model.isRenamingGroup = focused
                        if !focused { finish() }
                    }
                    .onAppear {
                        draft = group.customName ?? ""
                        isFocused = true
                        model.isRenamingGroup = true
                    }
            } else {
                HStack(spacing: 4) {
                    Text(group.name)
                        .font(.subheadline.weight(.semibold))
                        .lineLimit(1)
                    Button {
                        draft = group.customName ?? ""
                        isEditing = true
                    } label: {
                        Image(systemName: "pencil").font(.system(size: 9, weight: .semibold))
                    }
                    .buttonStyle(.plain)
                    .foregroundStyle(.secondary)
                    .help("Rename this group")
                }
                .frame(width: 104, alignment: .leading)
            }
            Text(model.activeGroupID == group.id
                 ? "Active · \(group.windows.count) windows"
                 : "\(group.windows.count) windows")
                .font(.caption2)
                .foregroundStyle(model.activeGroupID == group.id ? Color.accentColor : Color.secondary)
        }
    }

    private func finish() {
        if draft != (group.customName ?? "") {
            model.rename(group.id, to: draft)
        }
        isEditing = false
        model.isRenamingGroup = false
    }
}

private struct AccessibilityGateView: View {
    @ObservedObject var coordinator: WindowCoordinator
    let onGranted: () -> Void

    var body: some View {
        Group {
            if coordinator.accessibilityGranted {
                VStack(spacing: 12) {
                    Image(systemName: "checkmark.circle.fill")
                        .font(.system(size: 38)).foregroundStyle(.green)
                    Text("Accessibility access granted").font(.headline)
                    ProgressView()
                }
                .frame(width: 430, height: 260)
                .background(Color(nsColor: .windowBackgroundColor), in: RoundedRectangle(cornerRadius: 24, style: .continuous))
                .onAppear {
                    // Defer replacing the hosting view until SwiftUI finishes this update.
                    DispatchQueue.main.async(execute: onGranted)
                }
            } else {
                OnboardingView(coordinator: coordinator)
            }
        }
    }
}

private struct WindowOptionCard: View {
    let option: WindowSwitcherModel.Option
    let preview: NSImage?
    let canCapture: Bool
    let selectionNumber: Int?
    let isFocused: Bool
    let previewsEnabled: Bool
    let tooWideToShare: Bool

    var body: some View {
        VStack(spacing: 8) {
            ZStack(alignment: .topTrailing) {
                if previewsEnabled {
                    ZStack(alignment: .bottomLeading) {
                        if let preview {
                            Image(nsImage: preview)
                                .resizable()
                                .scaledToFit()
                                .frame(maxWidth: .infinity, maxHeight: 158)
                                .clipShape(RoundedRectangle(cornerRadius: 9, style: .continuous))
                            Image(nsImage: option.icon)
                                .resizable().scaledToFit()
                                .frame(width: 24, height: 24)
                                .padding(5)
                                .background(
                                    Color(nsColor: .windowBackgroundColor).opacity(0.94),
                                    in: RoundedRectangle(cornerRadius: 7)
                                )
                                .padding(7)
                        } else if canCapture {
                            // Capture is still in flight. Show the app icon so
                            // the card is usable immediately instead of blank.
                            Image(nsImage: option.icon)
                                .resizable().scaledToFit()
                                .frame(width: 56, height: 56)
                                .frame(maxWidth: .infinity, maxHeight: .infinity)
                                .background(Color(nsColor: .textBackgroundColor))
                        } else {
                            VStack(spacing: 7) {
                                Image(systemName: "rectangle.dashed.badge.record")
                                    .font(.system(size: 28))
                                Text("Allow Window Previews")
                                    .font(.caption.weight(.medium))
                            }
                            .foregroundStyle(.secondary)
                            .frame(maxWidth: .infinity, maxHeight: .infinity)
                            .background(Color(nsColor: .textBackgroundColor))
                        }
                    }
                    .frame(height: 158)
                } else {
                    Image(nsImage: option.icon)
                        .resizable()
                        .scaledToFit()
                        .frame(width: 46, height: 46)
                        .frame(maxWidth: .infinity)
                        .frame(height: 54)
                }
                if let selectionNumber {
                    Text("\(selectionNumber)")
                        .font(.caption.bold()).foregroundStyle(.white)
                        .frame(width: 24, height: 24)
                        .background(Color.accentColor, in: Circle())
                }
            }
            if tooWideToShare {
                Label("Needs \(Int(option.minimumWidth)) pt", systemImage: "arrow.left.and.right.square")
                    .font(.caption2.weight(.semibold))
                    .padding(.horizontal, 7).padding(.vertical, 2)
                    .background(Color.orange.opacity(0.16), in: Capsule())
                    .foregroundStyle(.orange)
                    .help("This window will not go narrow enough to share the display evenly")
            }
            if let groupName = option.groupName, let colorIndex = option.groupColorIndex {
                HStack(spacing: 5) {
                    Circle().fill(GroupPalette.color(at: colorIndex)).frame(width: 7, height: 7)
                    Text(groupName)
                }
                .font(.caption2.weight(.semibold))
                .padding(.horizontal, 8)
                .padding(.vertical, 3)
                .background(GroupPalette.color(at: colorIndex).opacity(0.12), in: Capsule())
            }
            VStack(spacing: 2) {
                Text(option.title).font(.subheadline.weight(.semibold)).lineLimit(2)
                HStack(spacing: 4) {
                    Text(option.appName)
                    if option.isMinimized { Text("• Minimized") }
                }
                .font(.caption).foregroundStyle(.secondary).lineLimit(1)
            }
        }
        .padding(10)
        // A fixed height per mode keeps every grid row the same size, which is
        // what lets ChooserMetrics work out how tall the panel needs to be.
        .frame(maxWidth: .infinity)
        .frame(height: ChooserMetrics.cardSize(previews: previewsEnabled).height - ChooserMetrics.cardSpacing)
        .background(selectionNumber == nil ? Color(nsColor: .controlBackgroundColor) : Color.accentColor.opacity(0.22), in: RoundedRectangle(cornerRadius: 14, style: .continuous))
        .overlay {
            RoundedRectangle(cornerRadius: 14, style: .continuous)
                .stroke(isFocused ? Color.accentColor : .clear, lineWidth: isFocused ? 3 : 0)
        }
    }
}

@MainActor
final class WindowSwitcherController {
    private let panel: KeyablePanel
    private let model: WindowSwitcherModel
    private let coordinator: WindowCoordinator
    private let appModel: AppModel
    private var keyMonitor: Any?
    private var pendingCreateNewGroup = false
    private var metrics = ChooserMetrics.resolve(
        optionCount: 0, hasGroups: false, previews: true, reservesPreview: false, on: nil
    )

    init(model appModel: AppModel) {
        self.appModel = appModel
        coordinator = appModel.coordinator
        model = WindowSwitcherModel(appModel: appModel)
        panel = KeyablePanel(
            contentRect: NSRect(x: 0, y: 0, width: 1080, height: 720),
            styleMask: [.borderless, .fullSizeContentView],
            backing: .buffered,
            defer: false
        )
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = true
        panel.level = .floating
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .transient]
        model.dismiss = { [weak self] in self?.close() }
        model.openSettings = { [weak self] in
            self?.close()
            SettingsWindow.open(model: appModel)
        }
    }

    func show(createNewGroup: Bool = false) {
        pendingCreateNewGroup = createNewGroup
        // Not just the cached flag: this also catches a permission granted since
        // launch and restarts, rather than flashing the gate at an already
        // permitted user.
        coordinator.pollAccessibilityState()
        guard coordinator.isTrusted else {
            showPermissionPanel()
            return
        }
        // `reload` performs the one and only window scan for this presentation.
        model.reload(createNewGroup: createNewGroup)
        let screen = NSScreen.screens.first { $0.frame.contains(NSEvent.mouseLocation) } ?? NSScreen.main
        metrics = ChooserMetrics.resolve(
            optionCount: model.options.count,
            hasGroups: !model.groups.isEmpty,
            previews: model.showWindowPreviews,
            reservesPreview: model.layoutPlan != nil,
            on: screen
        )
        panel.contentView = NSHostingView(
            rootView: WindowSwitcherView(
                model: model,
                metrics: metrics,
                onCancel: { [weak self] in self?.close() },
                onFocusFilter: { [weak self] in self?.focusFilter() }
            )
        )
        present(width: metrics.width, height: metrics.height)
        installKeyMonitor()
    }

    func close() {
        if let keyMonitor { NSEvent.removeMonitor(keyMonitor) }
        keyMonitor = nil
        panel.orderOut(nil)
        model.unload()
    }

    /// Puts the caret in the search field, ending a rename if one is running.
    private func focusFilter() {
        model.isRenamingGroup = false
        guard let field = Self.searchField(in: panel.contentView) else {
            panel.makeFirstResponder(nil)
            return
        }
        panel.makeFirstResponder(field)
    }

    private static func searchField(in view: NSView?) -> NSSearchField? {
        guard let view else { return nil }
        if let field = view as? NSSearchField { return field }
        for subview in view.subviews {
            if let found = searchField(in: subview) { return found }
        }
        return nil
    }

    private func showPermissionPanel() {
        panel.contentView = NSHostingView(rootView: AccessibilityGateView(
            coordinator: coordinator,
            onGranted: { [weak self] in
                guard let self else { return }
                self.show(createNewGroup: self.pendingCreateNewGroup)
            }
        ).frame(width: 430))
        present(width: 430, height: 340)
    }

    private func present(width requestedWidth: CGFloat, height requestedHeight: CGFloat) {
        let screen = NSScreen.screens.first(where: { $0.frame.contains(NSEvent.mouseLocation) }) ?? NSScreen.main
        let visible = screen?.visibleFrame
        // Never present larger than the display it lands on.
        let width = min(requestedWidth, (visible?.width ?? requestedWidth) - 24)
        let height = min(requestedHeight, (visible?.height ?? requestedHeight) - 24)
        panel.setContentSize(NSSize(width: width, height: height))
        if let frame = visible {
            panel.setFrameOrigin(NSPoint(x: frame.midX - width / 2, y: frame.midY - height / 2))
        }
        WindowActivator.activateSelf()
        panel.initialFirstResponder = nil
        panel.makeKeyAndOrderFront(nil)
        // Otherwise AppKit hands focus to the first text field it finds — the
        // group name — and every keystroke goes there instead of the filter.
        model.isRenamingGroup = false
        focusFilter()
        // SwiftUI installs its hosting view's responders asynchronously, so
        // claim the field again once that has settled.
        DispatchQueue.main.async { [weak self] in
            guard let self, !self.model.isRenamingGroup else { return }
            self.focusFilter()
        }
        // The chooser is usually opened from a global hot key while another
        // application owns activation. If macOS defers that transfer, the panel
        // comes up without key focus and the keyboard does nothing; claim it
        // again once the transfer lands.
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.12) { [weak self] in
            guard let self, self.panel.isVisible, !self.panel.isKeyWindow else { return }
            WindowActivator.activateSelf()
            self.panel.makeKeyAndOrderFront(nil)
            self.panel.makeFirstResponder(nil)
        }
    }

    private func installKeyMonitor() {
        if let keyMonitor { NSEvent.removeMonitor(keyMonitor) }
        keyMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
            guard let self, self.panel.isKeyWindow else { return event }
            // While a group name is being edited the keys belong to the field:
            // Space would otherwise never reach it and the arrows would move
            // card focus instead of the caret. This tracks a deliberate click
            // into the field; testing the panel's first responder instead meant
            // that the name field AppKit auto-focused on open swallowed every
            // keystroke, so typing renamed the group instead of filtering.
            if self.model.isRenamingGroup {
                guard event.keyCode == 53 else { return event }
                self.panel.makeFirstResponder(nil)
                self.model.isRenamingGroup = false
                return nil
            }
            let columns = self.metrics.columnCount
            // Only the navigation keys are taken. Everything else — letters,
            // digits, Space, Delete — belongs to the search field, which is a
            // real field and handles its own text.
            switch event.keyCode {
            case 53:                                    // Escape
                if !self.model.clearFilter() { self.close() }
            case 36, 76:                                // Return / keypad Enter
                if event.modifierFlags.contains(.command) {
                    self.model.submit()
                } else {
                    // Act on the focused window, the way Return works in any
                    // search-and-pick list. Command-Return arranges.
                    self.model.toggleFocused()
                }
            case 123: self.model.moveFocus(horizontal: -1, columns: columns)
            case 124: self.model.moveFocus(horizontal: 1, columns: columns)
            case 125: self.model.moveFocus(vertical: 1, columns: columns)
            case 126: self.model.moveFocus(vertical: -1, columns: columns)
            default: return event
            }
            return nil
        }
    }
}

@MainActor
final class StatusBarController: NSObject {
    private let statusItem: NSStatusItem
    private let switcher: WindowSwitcherController
    private let appModel: AppModel

    init(model: AppModel) {
        appModel = model
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        switcher = WindowSwitcherController(model: model)
        super.init()
        appModel.showCreateGroup = { [weak self] in
            self?.switcher.show(createNewGroup: true)
        }
        appModel.showChooser = { [weak self] in
            self?.switcher.show()
        }
        if let button = statusItem.button {
            button.image = MenuBarIcon.make()
            button.target = self
            button.action = #selector(statusItemClicked(_:))
            button.sendAction(on: [.leftMouseUp, .rightMouseUp])
        }
    }

    @objc private func statusItemClicked(_ sender: NSStatusBarButton) {
        if NSApp.currentEvent?.type == .rightMouseUp {
            showContextMenu()
        } else {
            switcher.show()
        }
    }

    private func showContextMenu() {
        let menu = NSMenu()
        if let name = appModel.coordinator.undoableArrangementName {
            let undo = NSMenuItem(
                title: "Undo \(name) Arrangement",
                action: #selector(undoArrangement),
                keyEquivalent: "z"
            )
            undo.keyEquivalentModifierMask = [.control, .option, .command]
            menu.addItem(undo)
            menu.addItem(.separator())
        }
        menu.addItem(withTitle: "Choose Windows", action: #selector(showSwitcher), keyEquivalent: "")
        menu.addItem(withTitle: "New Group — Control twice", action: #selector(createGroup), keyEquivalent: "")
        if !appModel.coordinator.groups.isEmpty {
            menu.addItem(.separator())
            for group in appModel.coordinator.groups {
                let item = NSMenuItem(
                    title: "\(group.name) · \(group.windows.count) windows",
                    action: #selector(activateGroupFromMenu(_:)),
                    keyEquivalent: ""
                )
                item.representedObject = group.id.uuidString
                item.image = MenuBarIcon.groupDot(colorIndex: group.colorIndex)
                item.target = self
                menu.addItem(item)
            }
        }
        if !appModel.coordinator.selectedWindows.isEmpty {
            menu.addItem(.separator())
            menu.addItem(withTitle: "Detach All Windows", action: #selector(detachAll), keyEquivalent: "")
        }
        menu.addItem(withTitle: "Settings…", action: #selector(showSettings), keyEquivalent: ",")
        menu.addItem(.separator())
        menu.addItem(withTitle: "Quit Window Columns", action: #selector(quit), keyEquivalent: "q")
        for item in menu.items { item.target = self }
        statusItem.menu = menu
        statusItem.button?.performClick(nil)
        statusItem.menu = nil
    }

    @objc private func showSwitcher() { switcher.show() }
    func showSwitcherPanel() { switcher.show() }
    @objc private func createGroup() { switcher.show(createNewGroup: true) }
    @objc private func activateGroupFromMenu(_ sender: NSMenuItem) {
        guard let value = sender.representedObject as? String, let id = UUID(uuidString: value) else { return }
        _ = appModel.coordinator.activateGroup(id)
    }
    @objc private func detachAll() { appModel.coordinator.detachAllWindows() }
    @objc private func undoArrangement() { appModel.coordinator.undoLastArrangement() }
    @objc private func showSettings() {
        SettingsWindow.open(model: appModel)
    }
    @objc private func quit() { NSApp.terminate(nil) }
}

@MainActor
final class ApplicationIconController: NSObject {
    private var appearanceObservation: NSKeyValueObservation?

    override init() {
        super.init()
        appearanceObservation = NSApp.observe(\.effectiveAppearance, options: [.initial, .new]) { [weak self] application, _ in
            Task { @MainActor in
                self?.applyIcon(for: application.effectiveAppearance)
            }
        }
    }

    private func applyIcon(for appearance: NSAppearance) {
        let isDark = appearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua
        let resource = isDark ? "AppIcon-v3-Dark" : "AppIcon-v3-Light"
        guard let url = Bundle.main.url(forResource: resource, withExtension: "png"),
              let image = NSImage(contentsOf: url) else { return }
        image.isTemplate = false
        NSApp.applicationIconImage = image
    }
}

final class AppDelegate: NSObject, NSApplicationDelegate {
    private var statusBarController: StatusBarController?
    private var applicationIconController: ApplicationIconController?
    private var groupHostManager: GroupHostManager?
    private var dividerOverlayController: DividerOverlayController?

    func applicationDidFinishLaunching(_ notification: Notification) {
        Task { @MainActor in
            self.applicationIconController = ApplicationIconController()
            NSApp.setActivationPolicy(.accessory)
            self.statusBarController = StatusBarController(model: AppModel.shared)
            self.groupHostManager = GroupHostManager(coordinator: AppModel.shared.coordinator)
            self.dividerOverlayController = DividerOverlayController(coordinator: AppModel.shared.coordinator)
            // The chooser performs the first window scan; doing one here too
            // just doubled the work on every launch.
            if !Self.wasLaunchedAtLogin {
                self.statusBarController?.showSwitcherPanel()
            }
        }
    }

    /// Opening the app should present the chooser, but a login-item launch is
    /// not the user opening the app — throwing a full-screen chooser in their
    /// face at every login is not what "launch at login" asks for.
    @MainActor
    private static var wasLaunchedAtLogin: Bool {
        guard AppModel.shared.store.preferences.launchAtLogin else { return false }
        // launchd sets this for an SMAppService login item; Finder and `open`
        // leave it unset or "0".
        let service = ProcessInfo.processInfo.environment["XPC_SERVICE_NAME"] ?? "0"
        return service != "0" && !service.isEmpty
    }

    func applicationWillTerminate(_ notification: Notification) {
        // Synchronously: termination does not wait for a scheduled task, so
        // dispatching this asynchronously meant the process usually exited
        // before the companions were stopped, leaving orphaned Command-Tab
        // entries behind.
        MainActor.assumeIsolated {
            dividerOverlayController?.close()
            groupHostManager?.stopAll()
        }
    }

    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        Task { @MainActor in
            self.statusBarController?.showSwitcherPanel()
        }
        return true
    }
}
