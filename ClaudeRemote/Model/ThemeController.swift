import SwiftUI

/// Holds the active light/dark mode (persisted across launches; the design ships
/// both palettes). The in-app toggle lives on the sessions-header avatar.
@MainActor
final class ThemeController: ObservableObject {
    @Published var mode: ThemeMode {
        didSet { UserDefaults.standard.set(mode.rawValue, forKey: Self.key) }
    }

    private static let key = "cr.theme"

    init() {
        if let raw = UserDefaults.standard.string(forKey: Self.key),
           let saved = ThemeMode(rawValue: raw) {
            mode = saved
        } else {
            mode = ProcessInfo.processInfo.environment["CR_LIGHT"] != nil ? .light : .dark
        }
    }

    func toggle() {
        mode = (mode == .dark) ? .light : .dark
    }
}
