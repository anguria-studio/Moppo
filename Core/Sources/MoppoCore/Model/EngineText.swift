import Foundation

/// Scan text carries its source so presentation can use the app language.
struct EngineText: Sendable, Equatable, ExpressibleByStringLiteral, ExpressibleByStringInterpolation {
    private let value: String.LocalizationValue?
    let english: String

    init(_ value: String.LocalizationValue) {
        self.value = value
        english = String(localized: value, table: "EngineSource", bundle: Bundle.main,
                         locale: Locale(identifier: "en_US_POSIX"))
    }

    init(english: String, display: String.LocalizationValue) {
        self.english = english
        value = display
    }

    /// Resolves English text supplied by a scanner or the tool rule registry.
    static func rule(_ source: String) -> Self {
        Self(stringLiteral: source)
    }

    private init(verbatim: String) {
        value = nil
        english = verbatim
    }

    static func verbatim(_ value: String) -> Self {
        Self(verbatim: value)
    }

    init(stringLiteral value: String) {
        self.init(english: value, display: String.LocalizationValue(stringLiteral: value))
    }

    init(stringInterpolation: String.LocalizationValue.StringInterpolation) {
        self.init(String.LocalizationValue(stringInterpolation: stringInterpolation))
    }

    private static let selectedLanguage = supportedLanguage(Bundle.main.preferredLocalizations.first)
    private static let selectedBundle = bundle(for: selectedLanguage)
    private static let selectedLocale = PresentationLocale.appLanguage(selectedLanguage)

    var localized: String {
        localized(bundle: Self.selectedBundle, locale: Self.selectedLocale)
    }

    func localized(language: String?, locale: Locale) -> String {
        let language = Self.supportedLanguage(language)
        return localized(bundle: Self.bundle(for: language),
                         locale: PresentationLocale.appLanguage(language, in: locale))
    }

    private func localized(bundle: Bundle?, locale: Locale) -> String {
        guard let value, let bundle else { return english }
        return String(localized: value, table: "Engine", bundle: bundle, locale: locale)
    }

    private static func supportedLanguage(_ language: String?) -> String {
        let requested = language.flatMap { Locale(identifier: $0).language.languageCode?.identifier }
        return requested.flatMap { Bundle.module.localizations.contains($0) ? $0 : nil } ?? "en"
    }

    private static func bundle(for language: String) -> Bundle? {
        guard let url = Bundle.module.url(forResource: language, withExtension: "lproj") else { return nil }
        return Bundle(url: url)
    }

    func string(localized: Bool) -> String {
        localized ? self.localized : english
    }
}

/// Uses the application language for plural rules and the user's region for formatting.
public enum PresentationLocale {
    public static func appLanguage(_ language: String, in locale: Locale = .current) -> Locale {
        let code = Locale.LanguageCode(language)
        guard locale.language.languageCode != code else { return locale }
        var components = Locale.Components(locale: locale)
        components.languageComponents.languageCode = code
        components.languageComponents.script = nil
        return Locale(components: components)
    }
}
