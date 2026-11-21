import Foundation
import Synchronization

// How Culla's text gets into the person's language (docs/localization.md).
//
// Every target that shows text has its own string catalog, `Localizable.xcstrings`, and one line
// that wraps its own bundle:
//
//     let localized = Localizer(bundle: .module)        // a package target
//     let localized = Localizer(bundle: .main)          // the app
//
// and asks it for text with the English sentence as the key:
//
//     localized("Reject \(count) photos?")             // key "Reject %lld photos?"
//     localized("hint.pick", default: "pick")          // a key of its own, where the same English
//                                                     // needs different words in another place
//
// The language is the same for every target, so the package's text never mixes with the app's:
//
// 1. a task-local override (`Localization.$override`), for tests that render Russian or Turkmen;
// 2. the process language, if the app set one (`Localization.setProcessLanguage(_:)`);
// 3. English in a test process, whatever the Mac's language, so tests can assert English text;
// 4. otherwise the main bundle's preferred localization: the language the app itself runs in.
//
// Step 4 is deliberate. Foundation resolves a package bundle's language from the main bundle's
// localizations, and Culla does the same on purpose: a process whose main bundle has no Russian
// (a command-line tool, or the app before it declares ru and tk) shows English everywhere rather
// than Russian menus around English sentences. The app must list en, ru and tk among its own
// localizations for the package's Russian and Turkmen to show.
//
// Text is always read from the language's own `.lproj` with that language's `Locale`, so plural
// forms follow the language of the text (Russian has one, few, many and other) and numbers in the
// text are formatted for it. An entry not yet translated falls back to English, with English
// plural rules, instead of showing its key.

/// The languages Culla ships in.
public enum AppLanguage: String, CaseIterable, Sendable, Codable, Hashable {
    case english = "en"
    case russian = "ru"
    case turkmen = "tk"

    /// The language of a localization or locale identifier such as "ru", "ru-RU", "tk_TM" or
    /// "en-GB"; nil for a language Culla does not ship in.
    public init?(identifier: String) {
        let code = identifier.lowercased().split(whereSeparator: { $0 == "-" || $0 == "_" }).first.map(String.init) ?? ""
        self.init(rawValue: code)
    }

    /// The language's own locale: what tests and an explicit choice format with. English is
    /// British English, as Culla's English text is ("analysed", "P, X or U").
    public var locale: Locale { Locale(identifier: self == .english ? "en_GB" : rawValue) }
}

/// The language Culla's text is in, and formatting in that language.
public enum Localization {
    /// Renders text in this language within a task, whatever the process language is. Tests use
    /// it through `withLanguage(_:_:)`.
    @TaskLocal public static var override: AppLanguage?

    /// The language text is rendered in now. See the top of this file for the order of rules.
    public static var language: AppLanguage {
        if let override { return override }
        return processLanguage
    }

    /// The language of the process: the one set with `setProcessLanguage(_:)`, English in a test
    /// process, or else the main bundle's preferred localization (English if it is none of ours).
    public static var processLanguage: AppLanguage {
        if let chosen = chosenLanguage.withLock({ $0 }) { return chosen }
        return automaticLanguage
    }

    /// Sets the language for the whole process, or with nil goes back to the automatic choice.
    /// Text built afterwards uses it; text already on screen is not rebuilt. The app normally
    /// does not need this: setting `AppleLanguages` for the app (and relaunching) changes the
    /// main bundle's preferred localization, which also covers system-provided text.
    public static func setProcessLanguage(_ language: AppLanguage?) {
        chosenLanguage.withLock { $0 = language }
    }

    /// The locale numbers, sizes, lists and dates are formatted with: the person's own locale
    /// when its language is the language of the text (so their region's conventions apply),
    /// otherwise the language's locale with the person's region. Under an override, in tests, or
    /// with a language set for the process: the language's plain locale, the same on every Mac.
    public static var locale: Locale {
        let language = self.language
        if override != nil || isRunningTests || chosenLanguage.withLock({ $0 }) != nil {
            return language.locale
        }
        let current = Locale.autoupdatingCurrent
        if current.language.languageCode?.identifier == language.rawValue { return current }
        if let region = current.region?.identifier {
            return Locale(identifier: "\(language.rawValue)_\(region)")
        }
        return language.locale
    }

    /// Runs `body` with text rendered in `language`.
    public static func withLanguage<T>(_ language: AppLanguage, _ body: () throws -> T) rethrows -> T {
        try $override.withValue(language, operation: body)
    }

    /// Runs `body` with text rendered in `language`, for async code.
    public nonisolated(nonsending) static func withLanguage<T>(
        _ language: AppLanguage, _ body: nonisolated(nonsending) () async throws -> T
    ) async rethrows -> T {
        try await $override.withValue(language, operation: body)
    }

    // MARK: Formatting in the language of the text

    /// "1,240" in English, "1 240" in Russian.
    public static func number(_ value: Int) -> String {
        value.formatted(.number.locale(locale))
    }

    /// A decimal number with exactly `fractionDigits` digits after the separator: "0.26", "0,26".
    public static func decimal(_ value: Double, fractionDigits: Int) -> String {
        value.formatted(.number.precision(.fractionLength(fractionDigits)).grouping(.never).locale(locale))
    }

    /// A share as a whole percentage: 0.3 is "30%" in English, "30 %" in Russian.
    public static func percent(_ fraction: Double) -> String {
        let whole = (fraction * 100).rounded(.toNearestOrAwayFromZero) / 100
        return whole.formatted(.percent.precision(.fractionLength(0)).locale(locale))
    }

    /// A file size as Finder shows it: "8.2 GB", "8,2 ГБ".
    public static func bytes(_ value: Int64) -> String {
        value.formatted(.byteCount(style: .file).locale(locale))
    }

    /// The kind of list `list(_:_:)` makes.
    public enum ListKind: Sendable {
        /// "P, X and U"
        case and
        /// "P, X or U"
        case or
    }

    /// Items joined as the language joins them: "P, X or U", "P, X или U".
    public static func list(_ items: [String], _ kind: ListKind = .and) -> String {
        let type: ListFormatStyle<StringStyle, [String]>.ListType = kind == .and ? .and : .or
        return items.formatted(.list(type: type).locale(locale))
    }

    // MARK: Test processes

    /// True in a process that runs tests (XCTest or Swift Testing, under Xcode or `swift test`).
    /// Text there is English unless a test asks for another language, so tests that assert
    /// English pass on a Mac set to Russian too.
    public static let isRunningTests: Bool = {
        let environment = ProcessInfo.processInfo.environment
        for name in ["XCTestConfigurationFilePath", "XCTestBundlePath", "XCTestSessionIdentifier"]
        where environment[name] != nil {
            return true
        }
        let process = ProcessInfo.processInfo.processName
        if process == "xctest" || process.hasPrefix("swiftpm-testing-helper") { return true }
        if Bundle.main.bundleURL.pathExtension == "xctest" { return true }
        return NSClassFromString("XCTestCase") != nil
    }()

    // MARK: Private

    private static let chosenLanguage = Mutex<AppLanguage?>(nil)

    private static let automaticLanguage: AppLanguage = {
        if isRunningTests { return .english }
        for identifier in Bundle.main.preferredLocalizations {
            if let language = AppLanguage(identifier: identifier) { return language }
        }
        return .english
    }()
}

/// Reads text from one bundle's string catalog in the language of `Localization`.
///
/// Each target keeps one, for its own bundle: `let localized = Localizer(bundle: .module)`.
public struct Localizer: Sendable {
    public let bundle: Bundle
    /// The catalog's name without extension; nil for `Localizable`.
    public let table: String?

    public init(bundle: Bundle, table: String? = nil) {
        self.bundle = bundle
        self.table = table
    }

    /// The text for a key that is its English value: `localized("Reject \(n) photos?")` reads the
    /// entry "Reject %lld photos?". Interpolated integers select the plural form.
    public func callAsFunction(_ value: String.LocalizationValue) -> String {
        let language = Localization.language
        if language != .english, let languageBundle = Self.bundle(bundle, language) {
            let locale = Localization.locale
            let text = String(localized: value, table: table, bundle: languageBundle, locale: locale)
            // A table that does not exist gives the key itself, as an entry not yet translated
            // does: the same result means there is no translation.
            let untranslated = String(localized: value, table: Self.noTable, bundle: languageBundle, locale: locale)
            if text != untranslated { return text }
        }
        let englishBundle = Self.bundle(bundle, .english) ?? bundle
        if Localization.isRunningTests, let key = Self.key(of: value), !Self.has(key, englishBundle, table) {
            return Self.missing(key)
        }
        return String(localized: value, table: table, bundle: englishBundle, locale: Self.englishLocale(language))
    }

    /// The text for an entry with a key of its own and `default` as its English value, for when
    /// the same English needs different words in different places:
    /// `localized("hint.pick", default: "pick")`.
    public func callAsFunction(_ key: StaticString, default value: String.LocalizationValue) -> String {
        let language = Localization.language
        let keyText = "\(key)"
        if language != .english, let languageBundle = Self.bundle(bundle, language) {
            let found = languageBundle.localizedString(forKey: keyText, value: Self.sentinel, table: table)
            // An entry not yet translated is compiled as its own key.
            if found != Self.sentinel, found != keyText {
                return String(localized: key, defaultValue: value, table: table, bundle: languageBundle, locale: Localization.locale)
            }
        }
        let englishBundle = Self.bundle(bundle, .english) ?? bundle
        if Localization.isRunningTests, !Self.has(keyText, englishBundle, table) {
            return Self.missing(keyText)
        }
        return String(localized: key, defaultValue: value, table: table, bundle: englishBundle, locale: Self.englishLocale(language))
    }

    // MARK: Private

    private static let noTable = "Culla-no-such-table"
    private static let sentinel = "\u{1}Culla-missing\u{1}"
    private static let bundles = Mutex<[String: Bundle]>([:])

    /// The `.lproj` of `language` inside `bundle` as a bundle of its own, or nil when the bundle
    /// has no such localization (no entry of the catalog is translated into it yet).
    private static func bundle(_ bundle: Bundle, _ language: AppLanguage) -> Bundle? {
        let cacheKey = bundle.bundlePath + "|" + language.rawValue
        if let cached = bundles.withLock({ $0[cacheKey] }) { return cached }
        guard let path = bundle.path(forResource: language.rawValue, ofType: "lproj"), let found = Bundle(path: path) else {
            return nil
        }
        bundles.withLock { $0[cacheKey] = found }
        return found
    }

    /// English text with the plural rules of English; numbers in the language's own style when
    /// the text falls back from another language.
    private static func englishLocale(_ language: AppLanguage) -> Locale {
        language == .english ? Localization.locale : AppLanguage.english.locale
    }

    private static func has(_ key: String, _ bundle: Bundle, _ table: String?) -> Bool {
        bundle.localizedString(forKey: key, value: sentinel, table: table) != sentinel
    }

    /// In tests, a key with no entry in the catalog shows as such, so a test of the English text
    /// fails when code and catalog disagree.
    private static func missing(_ key: String) -> String {
        "⟦missing catalog entry: \(key)⟧"
    }

    /// The catalog key of a value, read from its encoded form; nil if that form is not the one
    /// expected. Used in test processes only.
    private static func key(of value: String.LocalizationValue) -> String? {
        struct Encoded: Decodable { var key: String }
        guard let data = try? JSONEncoder().encode(value) else { return nil }
        return (try? JSONDecoder().decode(Encoded.self, from: data))?.key
    }
}

/// The text of the CullaCore catalog.
let localized = Localizer(bundle: .module)
