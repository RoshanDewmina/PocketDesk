import Foundation

/// Full phrases keep translators in control of word order, prices and renewal periods.
enum CommerceLocalization {
    static func text(_ key: String, _ fallback: String, _ arguments: CVarArg...,
                     bundle: Bundle = .main, locale: Locale = .current) -> String {
        let format = bundle.localizedString(forKey: key, value: fallback, table: "Localizable")
        return String(format: format, locale: locale, arguments: arguments)
    }
}
