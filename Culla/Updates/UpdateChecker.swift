import AppKit
import CullaCore
import CullaUpdates
import Observation
import os

/// Check for updates: learns the newest version from cullaapp.com and says so. Every decision is
/// made in `CullaUpdates` (which also holds the one network request); this is the glue between it,
/// the settings, the welcome view's notice, the alerts and the browser.
///
/// - Automatic checks run after launch and whenever Culla becomes active, at most once a day,
///   only while the setting is on, and are silent unless a newer version for this Mac exists
///   that was not skipped. Then the welcome view shows one line; nothing appears over an open
///   shoot, and no dialog opens on its own.
/// - A manual check (Culla ▸ Check for Updates…, Settings ▸ General ▸ Check Now) always answers,
///   with an alert.
///
/// Culla never downloads or installs anything: Download opens the site in the browser.
@MainActor
@Observable
final class UpdateChecker {
    /// What a finished check found, with the versions the alert names.
    enum Outcome: Equatable {
        case upToDate(current: ReleaseVersion)
        case available(newest: ReleaseVersion, current: ReleaseVersion)
        case needsNewerSystem(newest: ReleaseVersion, minimumSystem: ReleaseVersion, system: ReleaseVersion)
        case failed

        var name: String {
            switch self {
            case .upToDate: "upToDate"
            case .available: "available"
            case .needsNewerSystem: "needsNewerSystem"
            case .failed: "failed"
            }
        }
    }

    enum Trigger: String {
        case automatic, manual
    }

    /// True while a check is under way; Check for Updates… and Check Now are disabled meanwhile.
    private(set) var isChecking = false
    /// The last finished check, for the automation dump.
    private(set) var lastOutcome: Outcome?
    private(set) var lastTrigger: Trigger?
    /// Checks finished since launch.
    private(set) var checksFinished = 0

    /// This copy of Culla's version, from its Info.plist; nil if it is not a dotted number.
    let current: ReleaseVersion?

    @ObservationIgnored private let settings: AppSettings
    /// Nil under automation: no network object exists then, and the harness supplies answers.
    @ObservationIgnored private var fetcher: (any UpdateFetching)?
    /// False under automation: the app never checks on its own then.
    @ObservationIgnored private let checksOnItsOwn: Bool
    @ObservationIgnored private var activeObserver: (any NSObjectProtocol)?
    /// The alert a manual check put up, while it is shown.
    @ObservationIgnored private(set) var shownAlert: NSAlert?
    @ObservationIgnored private var shownActions: [UpdateAlert.Action] = []
    /// What the last link would have opened, under automation, which never opens the browser.
    @ObservationIgnored private(set) var lastOpenedLink: URL?
    @ObservationIgnored private let isAutomation: Bool
    /// The window an alert sits on when no other is given: the main window; set by the app model.
    @ObservationIgnored weak var mainWindow: NSWindow?

    private static let log = Logger(subsystem: "com.kpirliyev.Culla", category: "updates")

    init(settings: AppSettings, fetcher: (any UpdateFetching)?, isAutomation: Bool) {
        self.settings = settings
        self.fetcher = fetcher
        self.isAutomation = isAutomation
        checksOnItsOwn = !isAutomation
        let text = Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? ""
        current = ReleaseVersion(text)
    }

    // MARK: - The welcome view's notice

    /// The newer version the welcome view names: found by the last answered check, newer than
    /// this copy, and not skipped.
    var notice: ReleaseVersion? {
        guard let current, let newest = settings.newestKnownVersion.flatMap(ReleaseVersion.init), newest > current else { return nil }
        if let skipped = settings.skippedUpdateVersion.flatMap(ReleaseVersion.init), skipped == newest { return nil }
        return newest
    }

    /// Skip This Version: no automatic notice for this version again. A newer one is shown.
    func skip(_ version: ReleaseVersion) {
        settings.skippedUpdateVersion = version.description
    }

    // MARK: - The setting

    var checksAutomatically: Bool { settings.checksForUpdatesAutomatically }

    /// Switching automatic checks off also takes the notice away; switching them on checks if a
    /// check is due.
    func setChecksAutomatically(_ on: Bool) {
        settings.checksForUpdatesAutomatically = on
        if on {
            checkIfDue()
        } else {
            settings.newestKnownVersion = nil
        }
    }

    // MARK: - Checking

    /// Starts checking on its own: now, if a check is due, and whenever Culla becomes active.
    func startAutomaticChecks() {
        guard checksOnItsOwn, activeObserver == nil else { return }
        activeObserver = NotificationCenter.default.addObserver(
            forName: NSApplication.didBecomeActiveNotification, object: nil, queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated { self?.checkIfDue() }
        }
        checkIfDue()
    }

    /// An automatic check, if `UpdateSchedule` says one is due.
    func checkIfDue(now: Date = Date()) {
        guard checksOnItsOwn, !isChecking,
              UpdateSchedule.isAutomaticCheckDue(enabled: settings.checksForUpdatesAutomatically, lastAttempt: settings.lastUpdateCheck, now: now)
        else { return }
        check(.automatic)
    }

    /// Culla ▸ Check for Updates… and Check Now: asks at once and answers with an alert on
    /// `window` (the main window when nil).
    func checkNow(window: NSWindow? = nil) {
        guard !isChecking else { return }
        check(.manual, window: window)
    }

    /// Runs one check. The attempt is recorded before it starts, so a failed one still counts for
    /// the schedule.
    @discardableResult
    func check(_ trigger: Trigger, window: NSWindow? = nil) -> Task<Void, Never>? {
        guard !isChecking else { return nil }
        isChecking = true
        settings.lastUpdateCheck = Date()
        let fetcher = fetcher
        return Task {
            // No fetcher (automation without a canned answer) is a check that got no answer.
            let document: UpdateDocument?
            do {
                document = try await fetcher?.fetch()
            } catch {
                Self.log.info("The check for updates failed: \(String(describing: error), privacy: .public)")
                document = nil
            }
            finish(trigger, outcome: outcome(for: document), window: window)
        }
    }

    private func outcome(for document: UpdateDocument?) -> Outcome {
        guard let document, let current else { return .failed }
        let system = ReleaseVersion.currentSystem
        do {
            switch try UpdateDecision.make(current: current, system: system, document: document) {
            case .upToDate: return .upToDate(current: current)
            case .available(let newest): return .available(newest: newest, current: current)
            case .needsNewerSystem(let newest, let minimum): return .needsNewerSystem(newest: newest, minimumSystem: minimum, system: system)
            }
        } catch {
            Self.log.info("The update file was not understood: \(String(describing: error), privacy: .public)")
            return .failed
        }
    }

    private func finish(_ trigger: Trigger, outcome: Outcome, window: NSWindow?) {
        isChecking = false
        lastOutcome = outcome
        lastTrigger = trigger
        checksFinished += 1
        settings.lastUpdateCheckFailed = outcome == .failed
        switch outcome {
        case .available(let newest, _): settings.newestKnownVersion = newest.description
        case .upToDate, .needsNewerSystem: settings.newestKnownVersion = nil
        // A failed check leaves what an earlier one found.
        case .failed: break
        }
        if trigger == .manual { present(outcome, on: window) }
    }

    // MARK: - Alerts and links

    private func present(_ outcome: Outcome, on window: NSWindow?) {
        let (alert, actions) = UpdateAlert.make(for: outcome)
        shownAlert = alert
        shownActions = actions
        let target = window ?? mainWindow
        guard let target, target.isVisible, !target.isSheet, target.attachedSheet == nil else {
            // No free window to sit on (another sheet is up): an alert of its own.
            if isAutomation { return }
            let response = alert.runModal()
            alertEnded(response)
            return
        }
        alert.beginSheetModal(for: target) { [weak self] response in
            MainActor.assumeIsolated { self?.alertEnded(response) }
        }
    }

    private func alertEnded(_ response: NSApplication.ModalResponse) {
        let index = response.rawValue - NSApplication.ModalResponse.alertFirstButtonReturn.rawValue
        let action = shownActions.indices.contains(index) ? shownActions[index] : .dismiss
        shownAlert = nil
        shownActions = []
        perform(action)
    }

    func perform(_ action: UpdateAlert.Action) {
        switch action {
        case .download: open(UpdateLinks.download)
        case .releaseNotes: open(UpdateLinks.releaseNotes(Localization.language))
        case .dismiss: break
        }
    }

    /// Opens a page in the default browser. Automation records it instead.
    private func open(_ url: URL) {
        lastOpenedLink = url
        if isAutomation { return }
        NSWorkspace.shared.open(url)
    }

    #if DEBUG
    /// The automation harness's stand-in for the network.
    func useFetcher(_ fetcher: any UpdateFetching) {
        self.fetcher = fetcher
    }

    /// Answers the shown alert as a click on its button `index` would.
    func answerAlert(button index: Int) -> Bool {
        guard let alert = shownAlert else { return false }
        let response = NSApplication.ModalResponse(rawValue: NSApplication.ModalResponse.alertFirstButtonReturn.rawValue + index)
        if let window = alert.window.sheetParent {
            window.endSheet(alert.window, returnCode: response)
        } else {
            alertEnded(response)
        }
        return true
    }
    #endif
}
