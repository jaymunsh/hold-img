import Foundation

/// In-app localization. Keys are the Korean source strings; translations
/// live in <lang>.lproj/Localizable.strings. Locales without a table fall
/// back to the key itself, so Korean ships as the default text.
@MainActor
enum L10n {
    /// Resolved display language: the in-app override from Settings,
    /// otherwise the system locale (Korean for ko-*, English otherwise).
    static var languageCode: String {
        switch SettingsStore.shared.language {
        case "ko", "en": return SettingsStore.shared.language
        default:
            return Locale.preferredLanguages.first?.hasPrefix("ko") == true
                ? "ko" : "en"
        }
    }

    static func tr(_ key: String) -> String {
        guard let path = Bundle.main.path(forResource: languageCode,
                                          ofType: "lproj"),
              let bundle = Bundle(path: path) else { return key }
        return bundle.localizedString(forKey: key, value: key, table: nil)
    }

    /// Format variant: the key's %@/%d placeholders are filled by args.
    static func tr(_ key: String, _ args: CVarArg...) -> String {
        String(format: tr(key), arguments: args)
    }
}
