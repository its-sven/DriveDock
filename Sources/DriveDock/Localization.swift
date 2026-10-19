import Foundation

// English is the development language: the English text in the code is the lookup key.
// Translations live in Resources/<language>.lproj/Localizable.strings, which build-app.sh
// copies into the app bundle; macOS picks the language from the system preferences.
//
// SwiftUI string literals (Text("…"), Button("…"), .help("…") …) are looked up
// automatically. Everything else goes through tr(). Text with values uses explicit
// format keys ("%lld of %lld connected") so scripts/check-localization.py can verify
// every key and its placeholders.

/// Localized text for `key`.
func tr(_ key: String) -> String {
    Bundle.main.localizedString(forKey: key, value: nil, table: nil)
}

/// Localized format string for `key`, filled with `args` (%@ for text, %lld for numbers).
func tr(_ key: String, _ args: CVarArg...) -> String {
    String(format: tr(key), locale: .current, arguments: args)
}
