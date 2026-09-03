import Foundation

@MainActor
final class LayoutStore: ObservableObject {
    @Published var layouts: [SavedLayout] { didSet { save() } }
    @Published var preferences: LayoutPreferences { didSet { save() } }

    private struct Payload: Codable {
        var layouts: [SavedLayout]
        var preferences: LayoutPreferences
    }

    private let key = "WindowColumns.savedState.v1"
    private let defaults: UserDefaults

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        if let data = defaults.data(forKey: key), let payload = try? JSONDecoder().decode(Payload.self, from: data) {
            layouts = payload.layouts
            preferences = payload.preferences
        } else {
            layouts = []
            preferences = LayoutPreferences()
        }
    }

    func layouts(for displayID: String) -> [SavedLayout] {
        layouts.filter { $0.displayID == displayID }
    }

    func upsert(_ layout: SavedLayout) {
        if let index = layouts.firstIndex(where: { $0.id == layout.id }) {
            layouts[index] = layout
        } else {
            layouts.append(layout)
        }
    }

    func delete(_ layout: SavedLayout) {
        layouts.removeAll { $0.id == layout.id }
    }

    private func save() {
        let payload = Payload(layouts: layouts, preferences: preferences)
        if let data = try? JSONEncoder().encode(payload) {
            defaults.set(data, forKey: key)
        }
    }
}
