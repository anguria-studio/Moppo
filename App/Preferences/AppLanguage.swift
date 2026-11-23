import Foundation

enum AppLanguage: String, CaseIterable, Identifiable, Sendable {
    case system
    case english = "en"
    case italian = "it"
    case french = "fr"
    case spanish = "es"

    private static let key = "AppleLanguages"

    var id: Self { self }

    var displayName: String {
        switch self {
        case .system: String(localized: "System Default")
        case .english: "English"
        case .italian: "Italiano"
        case .french: "Français"
        case .spanish: "Español"
        }
    }

    static var running: Self {
        firstSupported(in: MoppoResources.bundle.preferredLocalizations) ?? .english
    }

    static var macOSDefault: Self {
        let languages = UserDefaults.standard.persistentDomain(forName: UserDefaults.globalDomain)?[key] as? [String]
        return firstSupported(in: languages ?? []) ?? .english
    }

    static func saved(in domain: String) -> Self {
        let application = domain as CFString
        CFPreferencesSynchronize(application, kCFPreferencesCurrentUser, kCFPreferencesAnyHost)
        let languages = CFPreferencesCopyValue(key as CFString, application, kCFPreferencesCurrentUser, kCFPreferencesAnyHost) as? [String]
        return firstSupported(in: languages ?? []) ?? .system
    }

    private static func firstSupported(in languages: [String]) -> Self? {
        for identifier in languages {
            if let code = Locale(identifier: identifier).language.languageCode?.identifier,
               let language = Self(rawValue: code), language != .system {
                return language
            }
        }
        return nil
    }

    func save(in domain: String) {
        let application = domain as CFString
        let value: CFArray? = self == .system ? nil : [rawValue] as CFArray
        CFPreferencesSetValue(Self.key as CFString, value, application, kCFPreferencesCurrentUser, kCFPreferencesAnyHost)
        CFPreferencesSynchronize(application, kCFPreferencesCurrentUser, kCFPreferencesAnyHost)
    }
}
