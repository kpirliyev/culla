#if DEBUG && !APP_STORE
import AppKit
import CullaUpdates
import Foundation

/// Stands in for cullaapp.com under automation: the app never touches the network then. It
/// answers with a made-up update file (or no answer), so every decision is still made by
/// `CullaUpdates` exactly as for a real answer.
struct CannedUpdateFetcher: UpdateFetching {
    var document: UpdateDocument?
    /// How long the answer takes, so a script can see a check under way.
    var delay: Duration = .zero

    func fetch() async throws(UpdateCheckError) -> UpdateDocument {
        if delay > .zero { try? await Task.sleep(for: delay) }
        guard let document else { throw .transport(-1009) }
        return document
    }
}

/// The `updates` step: canned answers, manual and automatic checks, the alert's and the welcome
/// line's buttons, and the setting. See Scripts/README.md.
extension AutomationRunner {
    func updateStep(_ step: [String: Any]) async throws -> String {
        let updates = app.updates
        switch step["updates"] as? String {
        case "canned":
            // {"updates": "canned", "outcome": "available", "version": "1.1", "minimumSystem": "26.0"}
            let outcome = step["outcome"] as? String ?? ""
            let current = updates.current?.description ?? "1.0"
            let document: UpdateDocument?
            switch outcome {
            case "available":
                document = UpdateDocument(version: step["version"] as? String ?? "1.1",
                                          minimumSystem: step["minimumSystem"] as? String ?? "26.0", date: "2026-12-01")
            case "upToDate":
                document = UpdateDocument(version: step["version"] as? String ?? current, minimumSystem: "26.0", date: "2026-11-21")
            case "unpublished":
                document = UpdateDocument(version: current, minimumSystem: "26.0", date: "")
            case "needsNewerSystem":
                document = UpdateDocument(version: step["version"] as? String ?? "1.1",
                                          minimumSystem: step["minimumSystem"] as? String ?? "99.0", date: "2026-12-01")
            case "invalid":
                document = UpdateDocument(version: "1.1 beta", minimumSystem: "26.0", date: "2026-12-01")
            case "failed":
                document = nil
            default:
                throw Failure("\"canned\" needs an \"outcome\": available, upToDate, unpublished, needsNewerSystem, invalid or failed")
            }
            let delay = Duration.milliseconds(step["delayMs"] as? Int ?? 0)
            updates.useFetcher(CannedUpdateFetcher(document: document, delay: delay))
            return document.map { "\(outcome): \($0.version), macOS \($0.minimumSystem)" } ?? outcome

        case "check":
            // {"updates": "check", "from": "settings"}: Check Now in Settings; otherwise as Culla ▸
            // Check for Updates… (the alert on the main window). Waits for the alert, unless
            // "background": true (then {"updates": "awaitAlert"} waits).
            guard !updates.isChecking else { throw Failure("A check is already under way") }
            if step["from"] as? String == "settings" {
                let model = try settingsModel()
                guard settingsController?()?.isShown == true else { throw Failure("Settings is not shown") }
                model.checkForUpdatesNow()
            } else {
                updates.checkNow()
            }
            if step["background"] as? Bool == true { return "started" }
            return try await awaitAlert()

        case "awaitAlert":
            return try await awaitAlert()

        case "automatic":
            // As an automatic check that was due (automation never checks on its own).
            let before = updates.checksFinished
            updates.check(.automatic)
            try await waitForCheck(after: before)
            try await Task.sleep(for: .milliseconds(100))
            return "\(updates.lastOutcome?.name ?? "none"), notice \(updates.notice?.description ?? "none")"

        case "alert":
            // {"updates": "alert", "button": 0} or "button": "Later": a click on the alert's button.
            guard let alert = updates.shownAlert else { throw Failure("No update alert is shown") }
            let titles = alert.buttons.map(\.title)
            let index: Int
            if let number = step["button"] as? Int {
                index = number
            } else if let title = step["button"] as? String, let found = titles.firstIndex(of: title) {
                index = found
            } else {
                throw Failure("\"button\" is an index or one of \(titles)")
            }
            guard titles.indices.contains(index), updates.answerAlert(button: index) else { throw Failure("No button \(index) in \(titles)") }
            try await Task.sleep(for: .milliseconds(400))
            return titles[index]

        case "notice":
            // {"updates": "notice", "button": "skip"}: the welcome line's Download, Release Notes or
            // Skip This Version.
            guard let version = updates.notice else { throw Failure("The welcome view shows no update notice") }
            switch step["button"] as? String {
            case "download": updates.perform(.download)
            case "releaseNotes": updates.perform(.releaseNotes)
            case "skip": updates.skip(version)
            default: throw Failure("\"button\" is download, releaseNotes or skip")
            }
            try await Task.sleep(for: .milliseconds(150))
            return step["button"] as? String ?? ""

        case "automaticSetting":
            // {"updates": "automaticSetting", "value": false}: the Settings switch.
            guard let value = step["value"] as? Bool else { throw Failure("\"automaticSetting\" needs a \"value\"") }
            updates.setChecksAutomatically(value)
            try await Task.sleep(for: .milliseconds(100))
            return "\(value)"

        default:
            throw Failure("\"updates\" is canned, check, awaitAlert, automatic, alert, notice or automaticSetting")
        }
    }

    /// Waits until the manual check has finished and its alert is on screen.
    private func awaitAlert() async throws -> String {
        let updates = app.updates
        let deadline = Date().addingTimeInterval(10)
        while updates.isChecking || updates.shownAlert?.window.isVisible != true {
            guard Date() < deadline else { throw Failure("No alert was shown") }
            try await Task.sleep(for: .milliseconds(30))
        }
        // The sheet slides in.
        try await Task.sleep(for: .milliseconds(500))
        return updates.lastOutcome?.name ?? "none"
    }

    private func waitForCheck(after count: Int) async throws {
        let deadline = Date().addingTimeInterval(10)
        while app.updates.checksFinished == count {
            guard Date() < deadline else { throw Failure("The check did not finish") }
            try await Task.sleep(for: .milliseconds(20))
        }
    }

    /// The dump's `updates` object.
    func addUpdateState(to state: inout [String: Any]) {
        let updates = app.updates
        let settings = app.settings
        var dump: [String: Any] = [
            "isChecking": updates.isChecking,
            "checksAutomatically": settings.checksForUpdatesAutomatically,
            "lastCheckFailed": settings.lastUpdateCheckFailed,
            "checksFinished": updates.checksFinished,
            "current": updates.current?.description ?? NSNull(),
            "newestKnown": settings.newestKnownVersion ?? NSNull(),
            "skipped": settings.skippedUpdateVersion ?? NSNull(),
            "notice": updates.notice?.description ?? NSNull(),
            "noticeText": updates.notice.map(UpdateText.notice) ?? NSNull(),
            "lastOutcome": updates.lastOutcome?.name ?? NSNull(),
            "lastTrigger": updates.lastTrigger?.rawValue ?? NSNull(),
            "lastOpenedLink": updates.lastOpenedLink?.absoluteString ?? NSNull(),
            "lastCheckedText": UpdateText.lastChecked(settings.lastUpdateCheck, failed: settings.lastUpdateCheckFailed),
            "hasLastCheck": settings.lastUpdateCheck != nil,
        ]
        // Culla ▸ Check for Updates…, as the menu bar shows it now.
        if let appMenu = NSApp.mainMenu?.items.first?.submenu {
            appMenu.update()
            let title = localized("menu.checkForUpdates", default: "Check for Updates…")
            if let item = appMenu.items.first(where: { $0.title == title }) {
                dump["menuItem"] = ["title": item.title, "enabled": item.isEnabled, "index": appMenu.index(of: item)] as [String: Any]
            }
        }
        if let alert = updates.shownAlert {
            let parent = alert.window.sheetParent
            dump["alert"] = [
                "message": alert.messageText,
                "detail": alert.informativeText,
                "buttons": alert.buttons.map(\.title),
                "on": parent?.identifier?.rawValue == "settings" ? "settings" : (parent == nil ? "none" : "main"),
            ] as [String: Any]
        } else {
            dump["alert"] = NSNull()
        }
        state["updates"] = dump
        state["distribution"] = "direct"
    }
}
#elseif DEBUG
import Foundation

/// The App Store variant has no update check (the store updates the app): the `updates` step is
/// refused, and the dump says so with `"updates": null` and `"distribution": "appStore"`.
extension AutomationRunner {
    func updateStep(_ step: [String: Any]) async throws -> String {
        throw Failure("This is the App Store variant, which has no update check: the \"updates\" step is refused")
    }

    func addUpdateState(to state: inout [String: Any]) {
        state["updates"] = NSNull()
        state["distribution"] = "appStore"
    }
}
#endif
