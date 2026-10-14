import AppKit

/// The saved appearance for application windows and dialogs.
enum AppAppearance: String, CaseIterable, Identifiable, Sendable {
    case system, light, dark

    static let defaultsKey = "settings.appearance"

    var id: String { rawValue }

    var displayName: String {
        switch self {
        case .system: "System"
        case .light: "Light"
        case .dark: "Dark"
        }
    }

    static func saved(in defaults: UserDefaults) -> Self {
        defaults.string(forKey: defaultsKey).flatMap(Self.init(rawValue:)) ?? .system
    }

    @MainActor
    func apply(to application: NSApplication = .shared) {
        let appearance: NSAppearance? = switch self {
        case .system: nil
        case .light: NSAppearance(named: .aqua)
        case .dark: NSAppearance(named: .darkAqua)
        }
        guard application.appearance?.name != appearance?.name else { return }
        // A nil override keeps later system appearance changes active.
        application.appearance = appearance
    }
}
