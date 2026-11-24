// Left out of the App Store variant, which has no update check (see UpdateChecker.swift).
#if !APP_STORE
import AppKit
import CullaCore
import CullaUpdates

/// The answer to Culla ▸ Check for Updates… and Check Now, one alert per outcome. Each names the
/// versions inside whole sentences.
@MainActor
enum UpdateAlert {
    /// What a button of the alert does.
    enum Action: String {
        case download, releaseNotes, dismiss
    }

    /// The alert and what each of its buttons does, in order.
    static func make(for outcome: UpdateChecker.Outcome) -> (NSAlert, [Action]) {
        let alert = NSAlert()
        alert.alertStyle = .informational
        let text = UpdateText.alert(for: outcome)
        alert.messageText = text.message
        alert.informativeText = text.detail
        let actions: [Action]
        switch outcome {
        case .available:
            alert.addButton(withTitle: UpdateText.download)
            alert.addButton(withTitle: UpdateText.releaseNotes)
            alert.addButton(withTitle: localized("updates.later", default: "Later"))
            actions = [.download, .releaseNotes, .dismiss]
        case .upToDate, .needsNewerSystem, .failed:
            alert.addButton(withTitle: localized("button.ok", default: "OK"))
            actions = [.dismiss]
        }
        return (alert, actions)
    }
}

/// Every piece of text about updates, so the welcome view, the alerts, Settings and their tests
/// read the same catalog entries.
@MainActor
enum UpdateText {
    static var download: String { localized("updates.download", default: "Download") }
    static var releaseNotes: String { localized("updates.releaseNotes", default: "Release Notes") }
    static var skipThisVersion: String { localized("Skip This Version") }

    /// The welcome view's line: "Culla 1.1 is available."
    static func notice(_ version: ReleaseVersion) -> String {
        let version = version.description
        return localized("updates.notice", default: "Culla \(version) is available.")
    }

    static func alert(for outcome: UpdateChecker.Outcome) -> (message: String, detail: String) {
        switch outcome {
        case .upToDate(let current):
            let current = current.description
            return (localized("Culla is up to date"),
                    localized("Culla \(current) is the newest version."))
        case .available(let newest, let current):
            let newest = newest.description
            let current = current.description
            return (localized("A newer version of Culla is available"),
                    localized("Culla \(newest) is available; you have Culla \(current). Download it from cullaapp.com, then replace Culla in your Applications folder with it."))
        case .needsNewerSystem(let newest, let minimum, let system):
            let newest = newest.description
            let minimum = minimum.systemDescription
            let system = system.systemDescription
            return (localized("Culla \(newest) needs a newer macOS"),
                    localized("Culla \(newest) needs macOS \(minimum) or later, and this Mac has macOS \(system). The version you have keeps working."))
        case .failed:
            return (localized("Culla couldn’t check for updates"),
                    localized("Check that this Mac is connected to the internet, then try again."))
        }
    }

    // MARK: Settings

    static var settingTitle: String { localized("Check for updates automatically") }
    static var settingHelp: String {
        localized("Once a day Culla asks cullaapp.com which version is the newest. Nothing about you or your photos is sent.")
    }
    static var checkNow: String { localized("updates.checkNow", default: "Check Now") }
    static var checking: String { localized("updates.checking", default: "Checking…") }

    /// When Culla last checked, as a sentence: "Last checked 24 Nov 2026 at 10:42."
    static func lastChecked(_ date: Date?, failed: Bool) -> String {
        guard let date else { return localized("Culla hasn’t checked for updates yet.") }
        let when = date.formatted(Date.FormatStyle(date: .abbreviated, time: .shortened, locale: Localization.locale))
        return failed
            ? localized("The last check, \(when), got no answer.")
            : localized("Last checked \(when).")
    }
}
#endif
