import CullaAnalysis
import CullaCommands
import CullaCore
import Foundation
import Observation

/// The user's settings, saved in UserDefaults as they change. The Settings window (⌘,) shows
/// every one of them; a few are also changed from the menus, the toolbar and Review and Apply.
///
/// Every change takes effect at once: `changed` tells the app model, which passes it to the
/// open shoot, the key router's menus and the cache.
@MainActor
@Observable
final class AppSettings {
    /// What changed, for the app model to follow.
    enum Change {
        case defaultTuning
        case keyBindings
        /// Include subfolders, or treat RAW+JPEG as one photo: the open shoot is scanned again.
        case scanOptions
        case collapseStacks
        case cacheLimit
    }

    /// Called after every change the open shoot or the app must follow.
    @ObservationIgnored var changed: ((Change) -> Void)?

    /// After P, X or U on one photo, move to the next one.
    var advanceAfterDecision: Bool {
        didSet { defaults.set(advanceAfterDecision, forKey: Key.advanceAfterDecision) }
    }

    /// Scan the subfolders of a shoot folder too.
    var includeSubfolders: Bool {
        didSet {
            defaults.set(includeSubfolders, forKey: Key.includeSubfolders)
            if includeSubfolders != oldValue { changed?(.scanOptions) }
        }
    }

    /// A RAW file and the JPEG or HEIC of the same name are one photo (Settings ▸ Duplicates:
    /// "Treat RAW+JPEG as one photo").
    var pairRAWWithRendered: Bool {
        didSet {
            defaults.set(pairRAWWithRendered, forKey: Key.pairRAWWithRendered)
            if pairRAWWithRendered != oldValue { changed?(.scanOptions) }
        }
    }

    /// All Photos shows each stack as one tile until S expands them (Settings ▸ General).
    var collapseStacksInAllPhotos: Bool {
        didSet {
            defaults.set(collapseStacksInAllPhotos, forKey: Key.collapseStacksInAllPhotos)
            if collapseStacksInAllPhotos != oldValue { changed?(.collapseStacks) }
        }
    }

    /// Stack review shows Culla's best pick beside the current frame (Settings ▸ General: "Show
    /// best pick beside the current frame"; H in stack review). When off, the current frame
    /// fills the row. A preference for every shoot, not part of a shoot's session.
    var showsBestPickPane: Bool {
        didSet { defaults.set(showsBestPickPane, forKey: Key.showsBestPickPane) }
    }

    /// The most disk space the thumbnail cache may take, in gigabytes (Settings ▸ Performance).
    var cacheLimitGB: Double {
        didSet {
            let clamped = min(max(cacheLimitGB.rounded(), Self.cacheLimitRange.lowerBound), Self.cacheLimitRange.upperBound)
            if clamped != cacheLimitGB { cacheLimitGB = clamped; return }
            defaults.set(cacheLimitGB, forKey: Key.cacheLimitGB)
            if cacheLimitGB != oldValue { changed?(.cacheLimit) }
        }
    }

    static let cacheLimitRange: ClosedRange<Double> = 1...50
    static let defaultCacheLimitGB: Double = 5
    var cacheLimitBytes: Int64 { Int64(cacheLimitGB * 1_000_000_000) }

    /// Analyse fewer photos at once while the Mac runs on its battery (Settings ▸ Performance:
    /// "Analysis speed: reduced on battery").
    var reduceAnalysisOnBattery: Bool {
        didSet { defaults.set(reduceAnalysisOnBattery, forKey: Key.reduceAnalysisOnBattery) }
    }

    /// The grid's tile width in points, within `thumbnailSizeRange`.
    var thumbnailSize: Double {
        didSet {
            let clamped = Self.clampThumbnailSize(thumbnailSize)
            if clamped != thumbnailSize { thumbnailSize = clamped; return }
            defaults.set(thumbnailSize, forKey: Key.thumbnailSize)
        }
    }

    /// The detection settings shoots start from and follow until they are adjusted for themselves
    /// (Settings ▸ Eyes to Other). Stored as JSON so settings added later take their defaults.
    /// A shoot adjusted from its tuning panel keeps its own tuning, saved with its session, until
    /// "Save as Default" or "Reset to Default".
    var defaultTuning: Tuning {
        didSet {
            guard defaultTuning != oldValue else { return }
            if let data = try? JSONEncoder().encode(defaultTuning) { defaults.set(data, forKey: Key.tuning) }
            changed?(.defaultTuning)
        }
    }

    /// Which key sends which command. Saved only once it differs from the defaults, so a later
    /// version's new default keys reach people who never changed theirs.
    var keyBindings: KeyBindings {
        didSet {
            if keyBindings == .defaults {
                defaults.removeObject(forKey: Key.keyBindings)
            } else if let data = try? JSONEncoder().encode(keyBindings) {
                defaults.set(data, forKey: Key.keyBindings)
            }
            if keyBindings != oldValue { changed?(.keyBindings) }
        }
    }

    /// What happens to rejects on Apply, unless the Review and Apply screen changes it for one
    /// apply (Settings ▸ General: Reject action).
    var rejectAction: RejectAction {
        didSet { defaults.set(rejectAction.rawValue, forKey: Key.rejectAction) }
    }

    /// Write XMP sidecars on Apply (Settings ▸ General: Write XMP sidecars).
    var writeSidecars: Bool {
        didSet { defaults.set(writeSidecars, forKey: Key.writeSidecars) }
    }

    /// Which XMP fields a decision and a rating are written to (Settings ▸ General ▸ Sidecars).
    /// The defaults follow Bridge and Lightroom.
    var sidecarMapping: SidecarMapping {
        didSet {
            if let data = try? JSONEncoder().encode(sidecarMapping) { defaults.set(data, forKey: Key.sidecarMapping) }
        }
    }

    /// The application Open Keepers In opens the keepers with, chosen once and remembered.
    var editorApplication: URL? {
        didSet { defaults.set(editorApplication?.path, forKey: Key.editorApplication) }
    }

    /// The options a new Review and Apply screen starts with.
    var applyOptions: ApplyOptions {
        ApplyOptions(rejectAction: rejectAction, writeSidecars: writeSidecars, sidecarMapping: sidecarMapping)
    }

    /// When the person last cleared the recent list: sessions opened before then are not listed.
    var recentsClearedAt: Date? {
        didSet { defaults.set(recentsClearedAt, forKey: Key.recentsClearedAt) }
    }

    /// True once the welcome view's first-run introduction was dismissed, or a shoot was opened.
    var introductionDismissed: Bool {
        didSet { defaults.set(introductionDismissed, forKey: Key.introductionDismissed) }
    }

    /// The language Culla is shown in (Settings ▸ General ▸ Language); nil follows the system's
    /// language order, with English when none of Culla's languages is in it.
    ///
    /// A choice is stored as `AppleLanguages` in the app's own defaults: the chosen language first,
    /// then the person's system languages, so the panels AppKit draws for Culla (open panels,
    /// Services) fall back to a language the system has (macOS is not translated into Turkmen).
    /// Removing the key goes back to the system's order. Both take effect at the next launch,
    /// when the system picks the main bundle's localization; text on screen is not rebuilt.
    ///
    /// The choice itself is kept under its own key, read from this domain only: the automation
    /// harness's suite never sees the app's choice, nor the app the harness's.
    var language: AppLanguage? {
        didSet {
            guard language != oldValue else { return }
            if let language {
                defaults.set(language.rawValue, forKey: Key.language)
                defaults.set(Self.appleLanguages(choosing: language), forKey: Key.appleLanguages)
            } else {
                defaults.removeObject(forKey: Key.language)
                defaults.removeObject(forKey: Key.appleLanguages)
            }
        }
    }

    /// The choice Culla was started with. While `language` differs from it, Settings offers to
    /// reopen Culla so the change takes effect.
    let launchChoice: AppLanguage?

    /// The language choices Settings offers, each named in its own language (never translated).
    static func nativeName(_ language: AppLanguage) -> String {
        switch language {
        case .english: "English"
        case .russian: "Русский"
        case .turkmen: "Türkmençe"
        }
    }

    /// `AppleLanguages` for a chosen language: it first, then the system's own order without it.
    static func appleLanguages(choosing language: AppLanguage) -> [String] {
        let system = UserDefaults.standard.persistentDomain(forName: UserDefaults.globalDomain)?["AppleLanguages"] as? [String]
            ?? Locale.preferredLanguages
        let others = system.filter { AppLanguage(identifier: $0) != language }
        return [language.rawValue] + others
    }

    /// Ask cullaapp.com once a day which version is the newest (Settings ▸ General ▸ Updates).
    var checksForUpdatesAutomatically: Bool {
        didSet { defaults.set(checksForUpdatesAutomatically, forKey: Key.checksForUpdatesAutomatically) }
    }

    /// When Culla last tried to learn the newest version, whether or not it got an answer.
    /// Automatic checks are counted from it (`UpdateSchedule`).
    var lastUpdateCheck: Date? {
        didSet { defaults.set(lastUpdateCheck, forKey: Key.lastUpdateCheck) }
    }

    /// True when that last attempt got no answer, for the line in Settings.
    var lastUpdateCheckFailed: Bool {
        didSet { defaults.set(lastUpdateCheckFailed, forKey: Key.lastUpdateCheckFailed) }
    }

    /// The newer version the last answered check found for this Mac, "1.1": the welcome view's
    /// notice shows it until it is skipped, or this copy of Culla is that version or newer.
    var newestKnownVersion: String? {
        didSet { defaults.set(newestKnownVersion, forKey: Key.newestKnownVersion) }
    }

    /// The version Skip This Version was used on: no automatic notice for it, though Check for
    /// Updates still names it.
    var skippedUpdateVersion: String? {
        didSet { defaults.set(skippedUpdateVersion, forKey: Key.skippedUpdateVersion) }
    }

    /// The shoot window's sidebar and inspector widths, as the person last dragged them.
    var sidebarWidth: Double? {
        didSet { defaults.set(sidebarWidth, forKey: Key.sidebarWidth) }
    }

    var inspectorWidth: Double? {
        didSet { defaults.set(inspectorWidth, forKey: Key.inspectorWidth) }
    }

    static let thumbnailSizeRange: ClosedRange<Double> = 80...360
    static let defaultThumbnailSize: Double = 168
    static let thumbnailSizeStep: Double = 40

    static func clampThumbnailSize(_ value: Double) -> Double {
        min(max(value, thumbnailSizeRange.lowerBound), thumbnailSizeRange.upperBound)
    }

    @ObservationIgnored private let defaults: UserDefaults

    private enum Key {
        static let advanceAfterDecision = "advanceAfterDecision"
        static let includeSubfolders = "includeSubfolders"
        static let reduceAnalysisOnBattery = "reduceAnalysisOnBattery"
        static let thumbnailSize = "thumbnailSize"
        static let tuning = "tuning"
        static let keyBindings = "keyBindings"
        static let recentsClearedAt = "recentsClearedAt"
        static let rejectAction = "rejectAction"
        static let writeSidecars = "writeSidecars"
        static let sidecarMapping = "sidecarMapping"
        static let editorApplication = "editorApplication"
        static let pairRAWWithRendered = "pairRAWWithRendered"
        static let collapseStacksInAllPhotos = "collapseStacksInAllPhotos"
        static let cacheLimitGB = "cacheLimitGB"
        static let showsBestPickPane = "showsBestPickPane"
        static let introductionDismissed = "introductionDismissed"
        static let sidebarWidth = "sidebarWidth"
        static let inspectorWidth = "inspectorWidth"
        static let language = "language"
        static let checksForUpdatesAutomatically = "checksForUpdatesAutomatically"
        static let lastUpdateCheck = "lastUpdateCheck"
        static let lastUpdateCheckFailed = "lastUpdateCheckFailed"
        static let newestKnownVersion = "newestKnownVersion"
        static let skippedUpdateVersion = "skippedUpdateVersion"
        static let appleLanguages = "AppleLanguages"
    }

    /// `domain` is the defaults domain `defaults` writes to (the app's bundle identifier, or the
    /// automation suite's name): the language choice is read from it alone.
    init(defaults: UserDefaults, domain: String) {
        self.defaults = defaults
        advanceAfterDecision = defaults.object(forKey: Key.advanceAfterDecision) as? Bool ?? true
        includeSubfolders = defaults.object(forKey: Key.includeSubfolders) as? Bool ?? true
        reduceAnalysisOnBattery = defaults.object(forKey: Key.reduceAnalysisOnBattery) as? Bool ?? true
        let size = defaults.object(forKey: Key.thumbnailSize) as? Double ?? Self.defaultThumbnailSize
        thumbnailSize = Self.clampThumbnailSize(size)
        pairRAWWithRendered = defaults.object(forKey: Key.pairRAWWithRendered) as? Bool ?? true
        collapseStacksInAllPhotos = defaults.object(forKey: Key.collapseStacksInAllPhotos) as? Bool ?? true
        showsBestPickPane = defaults.object(forKey: Key.showsBestPickPane) as? Bool ?? true
        let limit = defaults.object(forKey: Key.cacheLimitGB) as? Double ?? Self.defaultCacheLimitGB
        cacheLimitGB = min(max(limit.rounded(), Self.cacheLimitRange.lowerBound), Self.cacheLimitRange.upperBound)
        defaultTuning = defaults.data(forKey: Key.tuning).flatMap { try? JSONDecoder().decode(Tuning.self, from: $0) } ?? Tuning()
        keyBindings = defaults.data(forKey: Key.keyBindings)
            .flatMap { try? JSONDecoder().decode(KeyBindings.self, from: $0) } ?? .defaults
        recentsClearedAt = defaults.object(forKey: Key.recentsClearedAt) as? Date
        rejectAction = defaults.string(forKey: Key.rejectAction).flatMap(RejectAction.init(rawValue:)) ?? .moveToRejectedFolder
        writeSidecars = defaults.object(forKey: Key.writeSidecars) as? Bool ?? true
        sidecarMapping = defaults.data(forKey: Key.sidecarMapping)
            .flatMap { try? JSONDecoder().decode(SidecarMapping.self, from: $0) } ?? SidecarMapping()
        editorApplication = defaults.string(forKey: Key.editorApplication).map { URL(fileURLWithPath: $0) }
        introductionDismissed = defaults.bool(forKey: Key.introductionDismissed)
        sidebarWidth = defaults.object(forKey: Key.sidebarWidth) as? Double
        inspectorWidth = defaults.object(forKey: Key.inspectorWidth) as? Double
        checksForUpdatesAutomatically = defaults.object(forKey: Key.checksForUpdatesAutomatically) as? Bool ?? true
        lastUpdateCheck = defaults.object(forKey: Key.lastUpdateCheck) as? Date
        lastUpdateCheckFailed = defaults.bool(forKey: Key.lastUpdateCheckFailed)
        newestKnownVersion = defaults.string(forKey: Key.newestKnownVersion)
        skippedUpdateVersion = defaults.string(forKey: Key.skippedUpdateVersion)
        let choice = (defaults.persistentDomain(forName: domain)?[Key.language] as? String).flatMap(AppLanguage.init(rawValue:))
        language = choice
        launchChoice = choice
    }
}
