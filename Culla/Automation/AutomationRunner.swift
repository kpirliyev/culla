#if DEBUG
import AppKit
import CullaCommands
import CullaCore
import CullaSession
import Foundation

/// Runs a UI automation script in a debug build: opens folders, presses keys through the same
/// router real key events use, sends commands, waits for work to settle, and writes PNG
/// snapshots of the window and JSON dumps of the session, then quits. See Scripts/README.md.
///
/// Launch arguments:
/// - `-CullaAutomation <script.json>`: the script. Its presence turns automation on.
/// - `-CullaAutomationOutput <folder>`: where results go (default: next to the script).
/// - `-CullaShoot <folder>`: replaces `$SHOOT` in the script's paths.
/// - `-CullaAutomationReset YES`: deletes the automation database, thumbnails and settings first.
///
/// Automation runs keep their own database, caches and settings (`AppEnvironment`), never touch
/// the window order or focus of other apps, and quit by themselves; a watchdog ends a run that
/// takes longer than the script's `timeout`.
@MainActor
final class AutomationRunner {
    static private(set) var isActive = false

    private enum Argument {
        static let script = "CullaAutomation"
        static let output = "CullaAutomationOutput"
        static let shoot = "CullaShoot"
        static let reset = "CullaAutomationReset"
    }

    static func scriptPath() -> String? {
        UserDefaults.standard.string(forKey: Argument.script)
    }

    /// Clears the automation database, thumbnails and settings when asked, before anything opens them.
    static func prepareEnvironment(_ environment: AppEnvironment) {
        guard UserDefaults.standard.bool(forKey: Argument.reset) else { return }
        try? FileManager.default.removeItem(at: environment.dataFolder)
        try? FileManager.default.removeItem(at: environment.cacheFolder)
        if let suite = environment.defaultsSuite {
            UserDefaults.standard.removePersistentDomain(forName: suite)
            UserDefaults(suiteName: suite)?.synchronize()
        }
    }

    /// A key-down event typing `typed` on the key with virtual key code `keyCode`, with modifier
    /// names as in key steps ("shift", "cmd+shift").
    static func keyEvent(typed: String, keyCode: Int, modifiers: String?) -> NSEvent? {
        guard (0...0xFFFF).contains(keyCode) else { return nil }
        var flags: KeyChord.Modifiers = []
        if let modifiers, !modifiers.isEmpty {
            guard let parsed = KeyChord(string: modifiers + "+a") else { return nil }
            flags = parsed.modifiers
        }
        return NSEvent.keyEvent(
            with: .keyDown, location: .zero, modifierFlags: KeyRouter.menuModifiers(flags),
            timestamp: ProcessInfo.processInfo.systemUptime, windowNumber: 0, context: nil,
            characters: typed, charactersIgnoringModifiers: typed, isARepeat: false, keyCode: UInt16(keyCode))
    }

    struct Failure: Error, CustomStringConvertible {
        var description: String
        init(_ description: String) { self.description = description }
    }

    let scriptURL: URL
    let app: AppModel
    private let router: KeyRouter
    weak var windowController: MainWindowController?
    var outputFolder: URL
    let shootPath: String?
    var stepResults: [[String: Any]] = []
    let startedAt = Date()
    private var finished = false
    /// The Settings window, made on first use; set by the app delegate.
    var settingsController: (() -> SettingsWindowController?)?
    /// The Settings window if it was made, for the dump (which must not make it).
    var existingSettingsController: (() -> SettingsWindowController?)?
    /// The key each command's menu item shows; set by the app delegate.
    var menuKeyEquivalents: (() -> [String: String])?
    /// Named measurements from `record` steps, written into every dump as `measurements`.
    var measurements: [String: Any] = [:]
    /// The steps `loop` ran, with when each began, to line stalls up with them.
    var loopSteps: [[String: Any]] = []
    /// When the last `resetStalls` step ran, for the duration of a measured stretch.
    var stallWindowStartedAt = Date()
    /// The app delegate's About window and keyboard cheat sheet, for snapshots.
    var auxiliaryWindows: (() -> [String: NSWindow])?
    /// Shows the About window, the cheat sheet or (recorded only) the docs folder; set by the app delegate.
    var showAuxiliaryWindow: ((String) throws -> String)?
    /// What the Help menu did last, for the dump; set by the app delegate.
    var auxiliaryNote: (() -> [String: Any]?)?

    init(scriptPath: String, app: AppModel, router: KeyRouter) {
        scriptURL = URL(fileURLWithPath: scriptPath)
        self.app = app
        self.router = router
        let defaults = UserDefaults.standard
        shootPath = defaults.string(forKey: Argument.shoot)
        if let output = defaults.string(forKey: Argument.output) {
            outputFolder = URL(fileURLWithPath: output, isDirectory: true)
        } else {
            let name = scriptURL.deletingPathExtension().lastPathComponent
            outputFolder = scriptURL.deletingLastPathComponent().appendingPathComponent("out-\(name)", isDirectory: true)
        }
    }

    func start(window: MainWindowController) {
        Self.isActive = true
        windowController = window
        StallMonitor.shared.start()
        Task { await run() }
    }

    // MARK: - Running

    private func run() async {
        log("Script \(scriptURL.path)")
        let steps: [[String: Any]]
        let timeout: Double
        do {
            let data = try Data(contentsOf: scriptURL)
            guard let script = try JSONSerialization.jsonObject(with: data) as? [String: Any],
                  let list = script["steps"] as? [[String: Any]]
            else { throw Failure("The script must be an object with a \"steps\" list") }
            steps = list
            timeout = (script["timeout"] as? Double) ?? 180
            if let output = script["output"] as? String, UserDefaults.standard.string(forKey: Argument.output) == nil {
                outputFolder = resolve(output, directory: true)
            }
            if let size = script["window"] as? [Double], size.count == 2 {
                setWindowSize(width: size[0], height: size[1])
            }
        } catch {
            try? FileManager.default.createDirectory(at: outputFolder, withIntermediateDirectories: true)
            finish(ok: false, failedStep: nil, error: "Cannot read the script: \(error)")
            return
        }
        try? FileManager.default.createDirectory(at: outputFolder, withIntermediateDirectories: true)
        startWatchdog(seconds: timeout)
        log("Output \(outputFolder.path)")
        await app.reloadRecents()

        for (index, step) in steps.enumerated() {
            let action = Self.action(of: step)
            let began = Date()
            let beganAt = (StallMonitor.shared.now() * 10).rounded() / 10
            do {
                let detail = try await performExpectingFailure(action, step)
                let ms = Date().timeIntervalSince(began) * 1000
                var entry: [String: Any] = ["index": index, "action": action, "ok": true, "ms": (ms * 10).rounded() / 10, "atMs": beganAt]
                if let detail { entry["detail"] = detail }
                stepResults.append(entry)
                log("✓ \(index) \(action)\(detail.map { " — \($0)" } ?? "") (\(Int(ms)) ms)")
                if action == "quit" { return }
            } catch {
                stepResults.append(["index": index, "action": action, "ok": false, "error": String(describing: error)])
                log("✗ \(index) \(action): \(error)")
                finish(ok: false, failedStep: index, error: String(describing: error))
                quit()
                return
            }
        }
        finish(ok: true, failedStep: nil, error: nil)
        quit()
    }

    private static let actions = [
        "open", "openRecent", "close", "wait", "sleep", "key", "keys", "command", "group", "click",
        "windowSize", "snapshot", "dump", "expect", "resetStalls", "settings", "log", "quit",
        "injectScores", "zoom", "pan", "contextMenu", "band", "menuItem", "loupeMouse",
        "analysis", "tuning", "confirm", "popover", "faceCell", "comparePane",
        "applyScreen", "applyAction", "applyFocus", "fault", "releaseHold", "undoApply", "bannerAction",
        "copyKeepersTo", "fixture", "rescan", "saveHash", "expectHash", "fileAction", "fileContains",
        "settingsWindow", "preset", "tuningAction", "bindKey", "keyRecorder", "cache", "expectMatch",
    ] + extraActions

    /// `"expectFailure": "<pattern>"` on any step: the step passes only when it fails, with an
    /// error whose text matches the regular expression, to check that something is refused.
    private func performExpectingFailure(_ action: String, _ step: [String: Any]) async throws -> String? {
        guard let pattern = step["expectFailure"] as? String else { return try await perform(action, step) }
        let detail: String?
        do {
            detail = try await perform(action, step)
        } catch {
            let text = String(describing: error)
            guard text.range(of: pattern, options: .regularExpression) != nil else {
                throw Failure("Failed as expected, but with \"\(text)\", which does not match \(pattern)")
            }
            return "failed as expected: \(text)"
        }
        throw Failure("Expected to fail with an error matching \(pattern), but passed\(detail.map { " (\($0))" } ?? "")")
    }

    static func action(of step: [String: Any]) -> String {
        actions.first { step[$0] != nil } ?? "unknown"
    }

    /// Runs one step. Returns a short note for the log, if any.
    func perform(_ action: String, _ step: [String: Any]) async throws -> String? {
        switch action {
        case "open":
            guard let path = step["open"] as? String else { throw Failure("\"open\" needs a folder path") }
            let url = resolve(path, directory: true)
            app.openFolder(at: url)
            try await waitWhileLoading(timeout: step["timeout"] as? Double ?? 120)
            if let problem = app.problem { throw Failure("Open failed: \(problem.title) \(problem.message)") }
            return url.lastPathComponent

        case "openRecent":
            if app.recents.isEmpty { await app.reloadRecents() }
            let recent: RecentSession?
            if let index = step["openRecent"] as? Int {
                recent = app.recents.indices.contains(index) ? app.recents[index] : nil
            } else if let name = step["openRecent"] as? String {
                recent = app.recents.first { $0.name == name }
            } else {
                recent = nil
            }
            guard let recent else { throw Failure("No such recent session: \(step["openRecent"] ?? "")") }
            app.openRecent(recent)
            try await waitWhileLoading(timeout: step["timeout"] as? Double ?? 120)
            if let problem = app.problem, step["allowProblem"] as? Bool != true {
                throw Failure("Open failed: \(problem.title)")
            }
            return recent.name

        case "close":
            app.closeShoot()
            try await Task.sleep(for: .milliseconds(100))
            return nil

        case "wait":
            let what = step["wait"] as? String ?? "idle"
            let timeout = step["timeout"] as? Double ?? 60
            switch what {
            case "idle":
                let seconds = try await waitUntilIdle(timeout: timeout)
                return String(format: "idle after %.0f ms", seconds * 1000)
            case "analysis", "grouping":
                let seconds = try await waitForAnalysis(grouping: what == "grouping", timeout: timeout)
                let idle = try await waitUntilIdle(timeout: timeout)
                return String(format: "%@ after %.0f ms, idle %.0f ms later", what, seconds * 1000, idle * 1000)
            case "confirmation":
                let seconds = try await waitForConfirmation(timeout: timeout)
                return String(format: "confirmation after %.0f ms", seconds * 1000)
            case "apply", "applied", "undone", "disconnected", "reconnected", "rescan", "held", "undoable", "recovery":
                return try await waitForDisk(what, timeout: timeout)
            default:
                throw Failure("\"wait\" is \"idle\", \"analysis\", \"grouping\" or \"confirmation\"")
            }

        case "analysis":
            guard let analysis = app.session?.analysis else { throw Failure("No analysis is running") }
            switch step["analysis"] as? String {
            case "pause":
                analysis.pause()
                try await waitFor(timeout: 10, "analysis to pause") { analysis.isPaused || analysis.isFinished }
            case "resume":
                analysis.resume()
                try await waitFor(timeout: 10, "analysis to resume") { !analysis.isPaused }
            default:
                throw Failure("\"analysis\" is \"pause\" or \"resume\"")
            }
            return analysis.phase.rawValue

        case "tuning":
            guard let session = app.session else { throw Failure("No shoot is open") }
            guard let values = step["tuning"] as? [String: Any] else { throw Failure("\"tuning\" needs an object of Tuning values") }
            if values["reset"] != nil {
                guard let name = values["reset"] as? String, let group = GroupID(rawValue: name) else { throw Failure("\"reset\" needs a group") }
                session.resetTuning(for: group)
            }
            var tuning = session.state.tuning
            for (name, value) in values where name != "reset" {
                guard let key = TuningKey(rawValue: name) else {
                    throw Failure("Unknown tuning value \(name). Values: \(TuningKey.allCases.map(\.rawValue).joined(separator: ", "))")
                }
                if let bool = value as? Bool, key.isSwitch {
                    key.set(bool ? 1 : 0, in: &tuning)
                } else if let number = value as? Double {
                    key.set(number, in: &tuning)
                } else {
                    throw Failure("\(name) needs a number\(key.isSwitch ? " or a Boolean" : "")")
                }
            }
            session.setTuning(tuning)
            try await Task.sleep(for: .milliseconds(30))
            return values.keys.sorted().joined(separator: ", ")

        case "confirm":
            _ = try await waitForConfirmation(timeout: step["timeout"] as? Double ?? 5)
            guard let shoot = windowController?.shootController else { throw Failure("No shoot is open") }
            let accept = (step["confirm"] as? Bool) ?? ((step["confirm"] as? String).map { $0 != "cancel" } ?? true)
            let question = shoot.confirmation?.messageText ?? ""
            if let expected = step["question"] as? String, expected != question {
                throw Failure("Confirmation: expected \"\(expected)\", got \"\(question)\"")
            }
            guard shoot.answerConfirmation(confirm: accept) else { throw Failure("No confirmation is shown") }
            try await Task.sleep(for: .milliseconds(50))
            return "\(accept ? "accepted" : "cancelled"): \(question)"

        case "popover":
            guard let session = app.session else { throw Failure("No shoot is open") }
            switch step["popover"] as? String {
            case "tuning":
                if session.tuningPanelGroup == nil { session.openTuningPanel() }
                guard session.tuningPanelGroup != nil else { throw Failure("\(session.group.title) has no tuning panel") }
                try await waitFor(timeout: 5, "the tuning panel") {
                    self.windowController?.shootController?.photoArea.tuningPopover?.isShown == true
                }
            case "close":
                session.closeTuningPanel()
                try await waitFor(timeout: 5, "the tuning panel to close") {
                    self.windowController?.shootController?.photoArea.tuningPopover == nil
                }
            default:
                throw Failure("\"popover\" is \"tuning\" or \"close\"")
            }
            try await Task.sleep(for: .milliseconds(100))
            return step["popover"] as? String

        case "sleep":
            let seconds = step["sleep"] as? Double ?? 0.5
            try await Task.sleep(for: .milliseconds(Int(seconds * 1000)))
            return nil

        case "key" where step["keyCode"] != nil:
            // {"key": "з", "keyCode": 35, "modifiers": "shift"}: a key event as another keyboard
            // layout delivers it (the typed characters on the key with that virtual key code),
            // read by the same conversion real events go through.
            guard let typed = step["key"] as? String, let code = step["keyCode"] as? Int,
                  let event = Self.keyEvent(typed: typed, keyCode: code, modifiers: step["modifiers"] as? String) else {
                throw Failure("\"key\" with \"keyCode\" needs the typed characters and a virtual key code")
            }
            guard let chord = KeyRouter.chord(for: event) else { throw Failure("No chord for \(typed) on key \(code)") }
            guard router.route(chord) else { throw Failure("The key \(typed) (\(chord.description)) is not bound to a command") }
            try await Task.sleep(for: .milliseconds(Int((step["interval"] as? Double ?? 0.03) * 1000)))
            let command = router.lastRouted?.command?.rawValue ?? "?"
            return "\(typed) on key \(code) → \(chord.description) → \(command)\(router.lastRouted?.performed == false ? " (unavailable)" : "")"

        case "key", "keys":
            let names: [String]
            if let single = step["key"] as? String {
                names = Array(repeating: single, count: max(1, step["repeat"] as? Int ?? 1))
            } else if let list = step["keys"] as? [String] {
                names = list
            } else {
                throw Failure("\"key\" needs a string, \"keys\" a list of strings")
            }
            let interval = step["interval"] as? Double ?? 0.03
            var unavailable = 0
            for name in names {
                guard let chord = KeyChord(string: name) else { throw Failure("Not a key: \(name)") }
                guard router.route(chord) else { throw Failure("The key \(name) is not bound to a command") }
                if router.lastRouted?.performed == false { unavailable += 1 }
                try await Task.sleep(for: .milliseconds(Int(interval * 1000)))
            }
            let first = names.first ?? ""
            let command = router.lastRouted?.command?.rawValue ?? "?"
            return names.count == 1
                ? "\(first) → \(command)\(unavailable > 0 ? " (unavailable)" : "")"
                : "\(names.count) keys\(unavailable > 0 ? ", \(unavailable) unavailable" : "")"

        case "command":
            guard let name = step["command"] as? String, let command = Command(rawValue: name) else {
                throw Failure("Unknown command: \(step["command"] ?? "")")
            }
            let count = max(1, step["repeat"] as? Int ?? 1)
            var performed = 0
            for _ in 0..<count {
                if app.perform(command) { performed += 1 }
                try await Task.sleep(for: .milliseconds(Int((step["interval"] as? Double ?? 0.03) * 1000)))
            }
            if performed == 0, step["allowUnavailable"] as? Bool != true {
                throw Failure("The command \(name) is not available now")
            }
            return "\(name) ×\(performed)"

        case "group":
            guard let name = step["group"] as? String, let group = GroupID(rawValue: name) else {
                throw Failure("Unknown group: \(step["group"] ?? ""). Groups: \(GroupID.allCases.map(\.rawValue).joined(separator: ", "))")
            }
            guard let session = app.session else { throw Failure("No shoot is open") }
            session.selectGroup(group)
            try await Task.sleep(for: .milliseconds(50))
            return name

        case "click":
            guard let session = app.session else { throw Failure("No shoot is open") }
            let order = session.selectionOrder
            let id: String
            if let index = step["click"] as? Int {
                guard order.ids.indices.contains(index) else { throw Failure("No photo at \(index)") }
                id = order.ids[index]
            } else if let name = step["click"] as? String {
                id = name
            } else {
                throw Failure("\"click\" needs a photo id or a position")
            }
            if step["in"] as? String == "stack" {
                guard let review = windowController?.shootController?.photoArea.stackReview, review.filmstrip.click(id) else {
                    throw Failure("\(id) is not a frame of the stack in review")
                }
                try await Task.sleep(for: .milliseconds(30))
                return "\(id) in the stack's frames"
            }
            guard order.contains(id) else { throw Failure("\(id) is not shown in this group") }
            if step["in"] as? String == "filmstrip" {
                guard let filmstrip = windowController?.shootController?.photoArea.loupe?.filmstrip, filmstrip.click(id) else {
                    throw Failure("The filmstrip is not shown")
                }
                try await Task.sleep(for: .milliseconds(30))
                return "\(id) in the filmstrip"
            }
            let modifiers = (step["modifiers"] as? String ?? "").lowercased()
            if (step["count"] as? Int ?? 1) >= 2 {
                session.open(id)
            } else {
                let kind: ClickKind = modifiers.contains("shift") ? .extend : modifiers.contains("cmd") ? .toggle : .plain
                session.click(id, kind: kind)
            }
            try await Task.sleep(for: .milliseconds(30))
            return id

        case "windowSize":
            guard let size = step["windowSize"] as? [Double], size.count == 2 else { throw Failure("\"windowSize\" needs [width, height]") }
            setWindowSize(width: size[0], height: size[1])
            try await Task.sleep(for: .milliseconds(100))
            return "\(Int(size[0]))×\(Int(size[1]))"

        case "snapshot":
            let target: NSWindow?
            if step["window"] as? String == "settings" {
                guard let settings = settingsController?(), settings.isShown else { throw Failure("Settings is not shown") }
                settings.fitWindow(animate: false)
                target = settings.window
            } else if let name = step["window"] as? String {
                guard let window = auxiliaryWindows?()[name], window.isVisible else { throw Failure("The \(name) window is not shown") }
                target = window
            } else {
                target = windowController?.window
            }
            guard let name = step["snapshot"] as? String, let window = target else {
                throw Failure("\"snapshot\" needs a name")
            }
            try await Task.sleep(for: .milliseconds(60))
            let method = WindowSnapshotter.Method(rawValue: step["method"] as? String ?? "cache") ?? .cache
            let scale = (step["scale"] as? Double).map { CGFloat($0) }
            guard let image = WindowSnapshotter.capture(window, method: method, scale: scale) else {
                throw Failure("The window could not be drawn")
            }
            let url = outputFolder.appendingPathComponent("\(name).png")
            try WindowSnapshotter.writePNG(image, to: url)
            return "\(url.lastPathComponent) \(image.width)×\(image.height)"

        case "dump":
            guard let name = step["dump"] as? String else { throw Failure("\"dump\" needs a name") }
            var listing: [String: Any]?
            if step["listing"] as? Bool == true, let folder = app.session?.folder { listing = await Self.listing(of: folder) }
            let state = makeDump(includePhotos: step["photos"] as? Bool ?? true, listing: listing)
            let data = try JSONSerialization.data(withJSONObject: state, options: [.prettyPrinted, .sortedKeys])
            let url = outputFolder.appendingPathComponent("\(name).json")
            try data.write(to: url)
            return url.lastPathComponent

        case "expect":
            guard let expectations = step["expect"] as? [String: Any] else { throw Failure("\"expect\" needs an object") }
            let wantsListing = expectations.keys.contains { $0.hasPrefix("disk.listing") }
            var listing: [String: Any]?
            if wantsListing, let folder = app.session?.folder { listing = await Self.listing(of: folder) }
            let state = makeDump(includePhotos: true, listing: listing)
            var mismatches: [String] = []
            let tolerance = step["tolerance"] as? Double ?? 0
            for (path, expected) in expectations.sorted(by: { $0.key < $1.key }) {
                let actual = StateDump.value(at: path, in: state)
                if !StateDump.equal(actual, expected, tolerance: tolerance) {
                    mismatches.append("\(path): expected \(StateDump.text(expected)), got \(StateDump.text(actual))")
                }
            }
            if !mismatches.isEmpty { throw Failure(mismatches.joined(separator: "; ")) }
            return "\(expectations.count) checks"

        case "resetStalls":
            StallMonitor.shared.resetWindow()
            stallWindowStartedAt = Date()
            return nil

        case "settings":
            guard let values = step["settings"] as? [String: Any] else { throw Failure("\"settings\" needs an object") }
            if let value = values["advanceAfterDecision"] as? Bool { app.settings.advanceAfterDecision = value }
            if let value = values["includeSubfolders"] as? Bool { app.settings.includeSubfolders = value }
            if let value = values["thumbnailSize"] as? Double { app.settings.thumbnailSize = value }
            if let value = values["reduceAnalysisOnBattery"] as? Bool { app.settings.reduceAnalysisOnBattery = value }
            if let value = values["rejectAction"] as? String {
                guard let action = RejectAction(rawValue: value) else { throw Failure("rejectAction is moveToRejectedFolder, markOnly or moveToTrash") }
                app.settings.rejectAction = action
            }
            if let value = values["writeSidecars"] as? Bool { app.settings.writeSidecars = value }
            if values.keys.contains("editorApplication") {
                app.settings.editorApplication = (values["editorApplication"] as? String).map { URL(fileURLWithPath: $0) }
            }
            if values.keys.contains("simulateBattery") { app.power.simulatedBattery = values["simulateBattery"] as? Bool }
            if let value = values["pairRAWWithRendered"] as? Bool { app.settings.pairRAWWithRendered = value }
            if let value = values["collapseStacksInAllPhotos"] as? Bool { app.settings.collapseStacksInAllPhotos = value }
            if let value = values["showsBestPickPane"] as? Bool { app.settings.showsBestPickPane = value }
            if let value = values["cacheLimitGB"] as? Double { app.settings.cacheLimitGB = value }
            // "language": "ru", "tk", "en" or "system", as Settings ▸ General ▸ Language sets it.
            // Stored in the automation suite only; it takes effect at the next launch of a real
            // app, so scripts choose the running language with the script's own "language".
            if let value = values["language"] as? String {
                if value == "system" {
                    app.settings.language = nil
                } else {
                    guard let language = AppLanguage(rawValue: value) else { throw Failure("language is en, ru, tk or system") }
                    app.settings.language = language
                }
            }
            if values["quitAndReopen"] as? Bool == true { app.quitAndReopen() }
            if values.keys.contains("sidebarWidth") { app.settings.sidebarWidth = values["sidebarWidth"] as? Double }
            if values.keys.contains("inspectorWidth") { app.settings.inspectorWidth = values["inspectorWidth"] as? Double }
            if let value = values["writesRating"] as? Bool { app.settings.sidecarMapping.writesRating = value }
            if values.keys.contains("rejectedRating") { app.settings.sidecarMapping.rejectedRating = values["rejectedRating"] as? Int }
            if values.keys.contains("keptLabel") { app.settings.sidecarMapping.keptLabel = values["keptLabel"] as? String }
            if values.keys.contains("rejectedLabel") { app.settings.sidecarMapping.rejectedLabel = values["rejectedLabel"] as? String }
            // Detection defaults, as the Settings window's detection panes set them.
            if let defaults = values["default"] as? [String: Any] {
                let model = try settingsModel()
                for (name, value) in defaults {
                    guard let key = TuningKey(rawValue: name) else { throw Failure("Unknown tuning value \(name)") }
                    if let bool = value as? Bool, key.isSwitch {
                        model.setValue(key, bool ? 1 : 0)
                    } else if let number = value as? Double {
                        model.setValue(key, number)
                    } else {
                        throw Failure("\(name) needs a number\(key.isSwitch ? " or a Boolean" : "")")
                    }
                }
            }
            if let name = values["resetPane"] as? String {
                guard let pane = TuningPane(rawValue: name) else { throw Failure("Unknown pane \(name)") }
                try settingsModel().resetPane(pane)
            }
            try await Task.sleep(for: .milliseconds(30))
            return values.keys.sorted().joined(separator: ", ")

        case "log":
            return step["log"] as? String

        case "injectScores":
            guard let session = app.session else { throw Failure("No shoot is open") }
            if step["injectScores"] as? String == "burst" {
                let scores = try Self.burstScores(step)
                for id in scores.keys where !session.state.contains(id) { throw Failure("No photo \(id)") }
                session.injectScores(scores.mapValues { Optional($0) })
                try await Task.sleep(for: .milliseconds(30))
                return "a burst of \(scores.count) frames"
            }
            guard let entries = step["injectScores"] as? [String: Any] else { throw Failure("\"injectScores\" needs an object of photo ids") }
            var scores: [String: PhotoScores?] = [:]
            for (id, value) in entries {
                guard session.state.contains(id) else { throw Failure("No photo \(id)") }
                if value is NSNull {
                    scores[id] = .some(nil)
                } else if let spec = value as? [String: Any] {
                    scores[id] = try Self.syntheticScores(spec)
                } else {
                    throw Failure("Scores for \(id) must be an object or null")
                }
            }
            session.injectScores(scores)
            try await Task.sleep(for: .milliseconds(30))
            return "\(scores.count) photos"

        case "zoom":
            guard let session = app.session else { throw Failure("No shoot is open") }
            if step["zoom"] as? String == "fit" {
                session.setLoupeZoom(.fit)
            } else if let factor = step["zoom"] as? Double {
                let centre = try Self.point(step["centre"]) ?? session.loupeZoom.centre ?? UnitPoint(x: 0.5, y: 0.5)
                session.setLoupeZoom(.zoomed(factor: factor, centre: centre))
            } else {
                throw Failure("\"zoom\" needs \"fit\" or a factor (1 is 100%), with an optional \"centre\": [x, y]")
            }
            try await Task.sleep(for: .milliseconds(30))
            return "\(step["zoom"] ?? "")"

        case "pan":
            guard let session = app.session, case .zoomed(let factor, _) = session.loupeZoom else {
                throw Failure("\"pan\" needs a zoomed loupe")
            }
            guard let centre = try Self.point(step["pan"]) else { throw Failure("\"pan\" needs a centre [x, y] in unit image coordinates") }
            session.setLoupeZoom(.zoomed(factor: factor, centre: centre))
            try await Task.sleep(for: .milliseconds(30))
            return "\(centre.x), \(centre.y)"

        case "contextMenu":
            guard let id = step["contextMenu"] as? String else { throw Failure("\"contextMenu\" needs a photo id") }
            guard let photoArea = windowController?.shootController?.photoArea else { throw Failure("No shoot is open") }
            let menu: NSMenu?
            if step["in"] as? String == "filmstrip" {
                guard let filmstrip = photoArea.loupe?.filmstrip else { throw Failure("The filmstrip is not shown") }
                menu = filmstrip.contextMenu(for: id)
            } else {
                menu = photoArea.grid.contextMenu(for: id)
            }
            guard let menu else { throw Failure("No context menu for \(id)") }
            let titles = PhotoContextMenu.titles(of: menu)
            lastMenuTitles = titles
            if let expected = step["items"] as? [String], expected != titles {
                throw Failure("Menu items: expected \(expected), got \(titles)")
            }
            if let item = step["item"] as? String {
                guard PhotoContextMenu.perform(item, in: menu) else { throw Failure("No enabled item \(item) in \(titles)") }
                try await Task.sleep(for: .milliseconds(30))
                return "\(id): \(item)"
            }
            return "\(id): \(titles.joined(separator: " | "))"

        case "faceCell":
            guard let cell = step["faceCell"] as? [Int], cell.count == 2 else { throw Failure("\"faceCell\" needs [row, column]") }
            guard let session = app.session, let photoArea = windowController?.shootController?.photoArea else { throw Failure("No shoot is open") }
            let strip: FaceStripView? = session.viewMode == .stackReview ? photoArea.stackReview?.strip : photoArea.loupe?.faceStrip
            guard let strip, !strip.isHidden else { throw Failure("No face strip is shown") }
            guard strip.click(row: cell[0], column: cell[1]) else { throw Failure("No face at row \(cell[0]), column \(cell[1])") }
            try await Task.sleep(for: .milliseconds(30))
            return "row \(cell[0]), column \(cell[1])"

        case "comparePane":
            guard let index = step["comparePane"] as? Int else { throw Failure("\"comparePane\" needs a pane number from 0") }
            guard let compare = windowController?.shootController?.photoArea.compare, compare.click(pane: index) else {
                throw Failure("No compare pane \(index)")
            }
            try await Task.sleep(for: .milliseconds(30))
            return "pane \(index)"

        case "loupeMouse":
            guard let spec = step["loupeMouse"] as? [String: Any] else { throw Failure("\"loupeMouse\" needs an object") }
            guard let loupe = windowController?.shootController?.photoArea.loupe else { throw Failure("The loupe is not shown") }
            try loupeMouse(spec, in: loupe.imageView)
            try await Task.sleep(for: .milliseconds(50))
            return spec.keys.sorted().joined(separator: ", ")

        case "menuItem":
            guard let path = step["menuItem"] as? [String], !path.isEmpty, var menu = NSApp.mainMenu else {
                throw Failure("\"menuItem\" needs a path of titles, such as [\"File\", \"Open Recent\", \"Clear Menu\"]")
            }
            for (index, title) in path.enumerated() {
                menu.update()
                menu.delegate?.menuNeedsUpdate?(menu)
                guard let item = menu.items.first(where: { $0.title == title }) else {
                    throw Failure("No menu item \(title) in \(menu.title): \(menu.items.map(\.title))")
                }
                if index == path.count - 1 {
                    let enabled = (item.target as? NSMenuItemValidation)?.validateMenuItem(item) ?? item.isEnabled
                    guard enabled, let action = item.action else { throw Failure("\(title) is disabled") }
                    NSApp.sendAction(action, to: item.target, from: item)
                } else {
                    guard let submenu = item.submenu else { throw Failure("\(title) has no submenu") }
                    menu = submenu
                }
            }
            try await Task.sleep(for: .milliseconds(30))
            return path.joined(separator: " ▸ ")

        case "band":
            guard let ends = step["band"] as? [String], ends.count == 2 else { throw Failure("\"band\" needs [from id, to id]") }
            guard let grid = windowController?.shootController?.photoArea.grid else { throw Failure("No shoot is open") }
            let modifiers: NSEvent.ModifierFlags = (step["modifiers"] as? String ?? "").contains("shift") ? .shift : []
            try dragBand(in: grid, from: ends[0], to: ends[1], modifiers: modifiers)
            return ends.joined(separator: " → ")

        case "settingsWindow":
            guard let controller = settingsController?() else { throw Failure("No Settings window") }
            let name = step["settingsWindow"] as? String ?? "general"
            if name == "close" {
                controller.close()
                try await waitFor(timeout: 5, "Settings to close") { !controller.isShown }
                return "closed"
            }
            guard let pane = SettingsPane(rawValue: name) else {
                throw Failure("Panes: \(SettingsPane.allCases.map(\.rawValue).joined(separator: ", ")) or close")
            }
            if name != "keys" { controller.model.cancelRecording() }
            if step["viaKey"] as? Bool == true {
                // ⌘, through the key router, as a person opens it.
                guard router.route(KeyChord(",", .command)) else { throw Failure("⌘, is not bound") }
                controller.select(pane)
            } else {
                controller.show(pane: pane, activate: false)
            }
            try await waitFor(timeout: 5, "Settings to show") { controller.isShown }
            if pane == .performance { await app.measureCache() }
            try await Task.sleep(for: .milliseconds(200))
            controller.fitWindow(animate: false)
            return pane.title

        case "preset":
            guard let name = step["preset"] as? String, let preset = TuningPreset(rawValue: name) else {
                throw Failure("\"preset\" is lenient, balanced or strict")
            }
            try settingsModel().applyPreset(preset)
            try await Task.sleep(for: .milliseconds(30))
            return preset.title

        case "tuningAction":
            guard let session = app.session else { throw Failure("No shoot is open") }
            switch step["tuningAction"] as? String {
            case "saveAsDefault": session.saveTuningAsDefault()
            case "resetToDefault": session.resetTuningToDefault()
            case "useDefaultFromSettings": try settingsModel().useDefaultForOpenShoot()
            default: throw Failure("\"tuningAction\" is saveAsDefault, resetToDefault or useDefaultFromSettings")
            }
            try await Task.sleep(for: .milliseconds(30))
            await session.saver.flush()
            return step["tuningAction"] as? String

        case "bindKey":
            // Clicks a command's key in Settings ▸ Keys and presses a chord, through the recorder.
            guard let name = step["bindKey"] as? String, let command = Command(rawValue: name) else {
                throw Failure("\"bindKey\" needs a command name")
            }
            let model = try settingsModel()
            // "replacing": "cmd++" records over that key only; "add": true adds one; by default
            // the command's first key is replaced and its others stay.
            if let replacing = step["replacing"] as? String {
                guard let chord = KeyChord(string: replacing), app.settings.keyBindings.chords(for: command).contains(chord) else {
                    throw Failure("\(name) has no key \(replacing)")
                }
                model.startRecording(command, replacing: chord)
            } else {
                model.startRecording(command, adding: step["add"] as? Bool == true)
            }
            if let text = step["chord"] as? String {
                guard let chord = KeyChord(string: text) else { throw Failure("Not a key: \(text)") }
                model.record(chord)
            } else if let typed = step["typed"] as? String, let code = step["keyCode"] as? Int {
                // As the recorder reads a key event on another layout: "typed": "з", "keyCode": 35.
                guard let event = Self.keyEvent(typed: typed, keyCode: code, modifiers: step["modifiers"] as? String),
                      let chord = KeyRouter.chord(for: event) else { throw Failure("No chord for \(typed) on key \(code)") }
                model.record(chord)
            }
            if step["replace"] as? Bool == true { model.confirmConflict() }
            try await Task.sleep(for: .milliseconds(60))
            return model.pendingConflict?.message ?? "\(name) → \(app.settings.keyBindings.chords(for: command).map(\.description))"

        case "keyRecorder":
            let model = try settingsModel()
            switch step["keyRecorder"] as? String {
            case "confirm": model.confirmConflict()
            case "cancel": model.cancelRecording()
            case "resetAll": model.resetAllKeys()
            default: throw Failure("\"keyRecorder\" is confirm, cancel or resetAll")
            }
            try await Task.sleep(for: .milliseconds(60))
            return step["keyRecorder"] as? String

        case "cache":
            switch step["cache"] as? String {
            case "measure": await app.measureCache()
            case "clear": await app.clearCache(scores: false)
            case "clearWithMemory":
                // Also forgets the thumbnails held in memory, so new tiles must read the photos.
                app.thumbnails.clearMemory()
                await app.clearCache(scores: false)
            case "clearAll": await app.clearCache(scores: true)
            case "prune":
                app.pruneCache()
                try await Task.sleep(for: .milliseconds(300))
                await app.measureCache()
            default: throw Failure("\"cache\" is measure, clear, clearWithMemory, clearAll or prune")
            }
            let usage = app.cacheUsage
            return "thumbnails \(usage?.thumbnailBytes ?? -1) bytes, \(usage?.cachedScores ?? -1) scores"

        case "expectMatch":
            // Checks dump values against regular expressions, for text whose numbers come from a
            // detector and may move: {"expectMatch": {"summaryBanner": "^35 photos · 5 stacks · \\d+ likely rejects$"}}.
            guard let expectations = step["expectMatch"] as? [String: String] else { throw Failure("\"expectMatch\" needs an object of patterns") }
            let state = makeDump(includePhotos: true, listing: nil)
            var mismatches: [String] = []
            for (path, pattern) in expectations.sorted(by: { $0.key < $1.key }) {
                let actual = StateDump.value(at: path, in: state)
                let text = actual.map { "\($0)" } ?? "null"
                if text.range(of: pattern, options: .regularExpression) == nil {
                    mismatches.append("\(path): \(StateDump.text(actual)) does not match \(pattern)")
                }
            }
            if !mismatches.isEmpty { throw Failure(mismatches.joined(separator: "; ")) }
            return "\(expectations.count) patterns"

        case "quit":
            finish(ok: true, failedStep: nil, error: nil)
            quit()
            return nil

        default:
            if let detail = try await performApplyStep(action, step) { return detail.isEmpty ? nil : detail }
            if let detail = try await performExtraStep(action, step) { return detail.isEmpty ? nil : detail }
            throw Failure("Unknown step \(step.keys.sorted()). Steps: \(Self.actions.joined(separator: ", "))")
        }
    }

    // MARK: - Settings

    func settingsModel() throws -> SettingsModel {
        guard let controller = settingsController?() else { throw Failure("No Settings window") }
        return controller.model
    }

    func makeDump(includePhotos: Bool, listing: [String: Any]?) -> [String: Any] {
        var state = StateDump.make(app: app, windowController: windowController, includePhotos: includePhotos, listing: listing)
        StateDump.addSettings(to: &state, app: app, settings: existingSettingsController?(), menuKeys: menuKeyEquivalents?() ?? [:])
        addExtraState(to: &state)
        return state
    }

    // MARK: - Waiting

    /// Waits until analysis has finished and its final grouping is applied, or (`grouping`) also
    /// until the grouping asked for by the last tuning change is applied.
    private func waitForAnalysis(grouping: Bool, timeout: Double) async throws -> Double {
        let started = Date()
        guard let analysis = app.session?.analysis else { throw Failure("No analysis is running") }
        try await waitFor(timeout: timeout, grouping ? "grouping" : "analysis to finish") {
            analysis.isFinished && (!grouping || !analysis.groupingPending)
        }
        return Date().timeIntervalSince(started)
    }

    private func waitForConfirmation(timeout: Double) async throws -> Double {
        let started = Date()
        try await waitFor(timeout: timeout, "the confirmation") {
            self.windowController?.shootController?.confirmation != nil
                && self.windowController?.window?.attachedSheet != nil
        }
        return Date().timeIntervalSince(started)
    }

    func waitFor(timeout: Double, _ what: String, _ condition: () -> Bool) async throws {
        let deadline = Date().addingTimeInterval(timeout)
        while !condition() {
            if Date() > deadline {
                let phase = app.session?.analysis.map { " (analysis \($0.phase.rawValue), \($0.progress.done) of \($0.progress.total))" } ?? ""
                throw Failure("Waited \(Int(timeout)) s for \(what)\(phase)")
            }
            try await Task.sleep(for: .milliseconds(25))
        }
    }

    func waitWhileLoading(timeout: Double) async throws {
        let deadline = Date().addingTimeInterval(timeout)
        try await Task.sleep(for: .milliseconds(20))
        while app.isLoading {
            if Date() > deadline { throw Failure("Still loading after \(Int(timeout)) s") }
            try await Task.sleep(for: .milliseconds(20))
        }
    }

    /// Waits until nothing is loading, saving or decoding, and every visible tile has its
    /// thumbnail (or the loupe its image). Returns how long that took.
    func waitUntilIdle(timeout: Double) async throws -> Double {
        let started = Date()
        var calm = 0
        while true {
            calm = isIdle() ? calm + 1 : 0
            if calm >= 3 { return Date().timeIntervalSince(started) }
            if Date().timeIntervalSince(started) > timeout {
                throw Failure("Not idle after \(Int(timeout)) s: \(busyDescription())")
            }
            try await Task.sleep(for: .milliseconds(25))
        }
    }

    private func isIdle() -> Bool {
        guard !app.isLoading, app.activity.isIdle else { return false }
        guard let window = windowController?.window else { return true }
        window.layoutIfNeeded()
        window.displayIfNeeded()
        guard let session = app.session, let shoot = windowController?.shootController else { return true }
        // Review and Apply covers the views: its thumbnails count as activity.
        if session.apply.isOpen { return !session.apply.isPreparing && !session.apply.isRunning }
        switch session.viewMode {
        case .grid:
            return shoot.photoArea.grid.visibleTilesWithoutImage == 0
        case .loupe:
            guard let focus = session.focus, session.state.photo(focus)?.isUnreadable == false else { return true }
            guard let loupe = shoot.photoArea.loupe else { return false }
            return session.loupeShownID == focus && loupe.isSettled && loupe.filmstrip.visibleTilesWithoutImage == 0
        case .compare:
            return shoot.photoArea.compare?.isSettled ?? false
        case .stackReview:
            guard let review = shoot.photoArea.stackReview else { return session.order.isEmpty }
            return review.isSettled
        case .duplicateReview:
            guard let review = shoot.photoArea.duplicateReview else { return session.order.isEmpty }
            return review.isSettled
        }
    }

    private func busyDescription() -> String {
        var parts = [app.activity.summary]
        if app.isLoading { parts.append("loading") }
        if let shoot = windowController?.shootController {
            parts.append("tiles without image: \(shoot.photoArea.grid.visibleTilesWithoutImage)")
        }
        return parts.filter { !$0.isEmpty }.joined(separator: ", ")
    }

    // MARK: - Helpers

    /// The titles of the last context menu a step opened, for the dump.
    private(set) var lastMenuTitles: [String] = []

    /// Scores made up for a test, from a script:
    /// `{"faces": [{"box": [x, y, w, h], "eyes": [left, right], "size": 0.2, "yaw": 0,
    /// "sharpness": 40, "peak": [x, y]}], "focus": [x, y], "sharpness": 50, "clipping": [0.4, 0.1]}`.
    /// Boxes and points are in unit image coordinates, origin top left. `size` defaults to the
    /// box's height.
    static func syntheticScores(_ spec: [String: Any]) throws -> PhotoScores {
        var scores = PhotoScores(analysedWidth: 1000, analysedHeight: 1000)
        for face in spec["faces"] as? [[String: Any]] ?? [] {
            guard let box = face["box"] as? [Double], box.count == 4 else { throw Failure("A face needs \"box\": [x, y, w, h]") }
            let eyes = face["eyes"] as? [Double]
            scores.faces.append(FaceScores(
                box: UnitRect(x: box[0], y: box[1], width: box[2], height: box[3]),
                sizeFraction: face["size"] as? Double ?? box[3],
                leftEyeOpenness: eyes?.first,
                rightEyeOpenness: eyes.flatMap { $0.count > 1 ? $0[1] : $0.first },
                yawDegrees: face["yaw"] as? Double ?? 0,
                sharpness: face["sharpness"] as? Double,
                sharpnessPeak: try point(face["peak"])
            ))
        }
        if let focus = try point(spec["focus"]) { scores.subjectPeak = focus }
        scores.subjectSharpness = spec["sharpness"] as? Double ?? 60
        scores.frameSharpness = scores.subjectSharpness
        if let clipping = spec["clipping"] as? [Double], clipping.count == 2 {
            scores.clippedHighlights = clipping[0]
            scores.clippedShadows = clipping[1]
        }
        return scores
    }

    /// Consistent faces for the frames of a burst, so the face strip, the best pick and the
    /// closed-eye outline can be exercised on generated photos:
    /// `{"injectScores": "burst", "frames": ["a.jpg", ...], "people": [{"box": [x, y, w, h], "eyes": 0.8, "size": 0.1}],
    /// "blink": [[frame, person]], "missing": [[frame, person]], "drift": 0.003, "sharpness": [55, 60, ...]}`.
    /// Each person stays at nearly the same place: the box moves by `drift` (unit coordinates) per
    /// frame to the right and by a small fixed wobble. A blink sets that face's eyes to 0.08; a
    /// missing face is left out. `sharpness` gives each frame's sharpness (default 60 for all), which
    /// is also its faces' sharpness. Frames and people count from 0.
    static func burstScores(_ step: [String: Any]) throws -> [String: PhotoScores] {
        guard let frames = step["frames"] as? [String], !frames.isEmpty else { throw Failure("A burst needs \"frames\": [photo ids]") }
        guard let people = step["people"] as? [[String: Any]] else { throw Failure("A burst needs \"people\": [{\"box\": [x, y, w, h]}]") }
        func pairs(_ key: String) throws -> Set<[Int]> {
            guard let value = step[key] else { return [] }
            guard let list = value as? [[Int]], list.allSatisfy({ $0.count == 2 }) else { throw Failure("\"\(key)\" is a list of [frame, person]") }
            return Set(list)
        }
        let blinks = try pairs("blink")
        let missing = try pairs("missing")
        let drift = step["drift"] as? Double ?? 0.003
        let sharpness = step["sharpness"] as? [Double] ?? []
        var result: [String: PhotoScores] = [:]
        for (frame, id) in frames.enumerated() {
            let frameSharpness = sharpness.indices.contains(frame) ? sharpness[frame] : 60
            var faces: [[String: Any]] = []
            for (person, spec) in people.enumerated() where !missing.contains([frame, person]) {
                guard let box = spec["box"] as? [Double], box.count == 4 else { throw Failure("A person needs \"box\": [x, y, w, h]") }
                let wobble = sin(Double(frame * 7 + person * 3)) * 0.002
                let x = box[0] + drift * Double(frame) + wobble
                let y = box[1] + cos(Double(frame * 5 + person)) * 0.002
                let eyes = blinks.contains([frame, person]) ? 0.08 : (spec["eyes"] as? Double ?? 0.8)
                faces.append([
                    "box": [x, y, box[2], box[3]], "eyes": [eyes, eyes], "sharpness": frameSharpness, "size": spec["size"] as? Double ?? box[3],
                    "peak": [x + box[2] / 2, y + box[3] * 0.4],
                ])
            }
            let focus: [Double] = (faces.first?["peak"] as? [Double]) ?? [0.5, 0.5]
            result[id] = try syntheticScores(["faces": faces, "focus": focus, "sharpness": frameSharpness])
        }
        return result
    }

    static func point(_ value: Any?) throws -> UnitPoint? {
        guard let value else { return nil }
        guard let list = value as? [Double], list.count == 2 else { throw Failure("A point is [x, y]") }
        return UnitPoint(x: list[0], y: list[1])
    }

    /// Mouse and trackpad input to the loupe, through its own event handlers. Points are unit
    /// image coordinates:
    /// - `{"doubleClick": [x, y]}`
    /// - `{"drag": [[x, y], [x, y]]}`: drags the photo (pans when zoomed)
    /// - `{"scroll": dy, "at": [x, y], "modifiers": "cmd"}`: scroll-wheel lines; with ⌘ or ⌥ it zooms
    /// - `{"magnify": 0.5, "at": [x, y]}`: a pinch, as the scroll view's own magnification does it
    private func loupeMouse(_ spec: [String: Any], in view: LoupeImageView) throws {
        guard let window = windowController?.window else { throw Failure("No window") }
        let document = view.document
        func windowPoint(_ unit: Any?) throws -> NSPoint {
            guard let point = try Self.point(unit) else { throw Failure("A point is [x, y]") }
            let local = NSPoint(x: point.x * view.pixelSize.width, y: point.y * view.pixelSize.height)
            return document.convert(local, to: nil)
        }
        func mouse(_ type: NSEvent.EventType, _ location: NSPoint, clicks: Int) -> NSEvent? {
            NSEvent.mouseEvent(
                with: type, location: location, modifierFlags: [], timestamp: ProcessInfo.processInfo.systemUptime,
                windowNumber: window.windowNumber, context: nil, eventNumber: 0, clickCount: clicks, pressure: 1
            )
        }
        if spec["doubleClick"] != nil {
            let location = try windowPoint(spec["doubleClick"])
            guard let first = mouse(.leftMouseDown, location, clicks: 1), let second = mouse(.leftMouseDown, location, clicks: 2) else {
                throw Failure("Could not make mouse events")
            }
            document.mouseDown(with: first)
            document.mouseUp(with: first)
            document.mouseDown(with: second)
        }
        if let ends = spec["drag"] as? [Any], ends.count == 2 {
            let from = try windowPoint(ends[0])
            let to = try windowPoint(ends[1])
            guard let down = mouse(.leftMouseDown, from, clicks: 1), let drag = mouse(.leftMouseDragged, to, clicks: 1),
                  let up = mouse(.leftMouseUp, to, clicks: 1)
            else { throw Failure("Could not make mouse events") }
            document.mouseDown(with: down)
            document.mouseDragged(with: drag)
            document.mouseUp(with: up)
        }
        if let lines = spec["scroll"] as? Double {
            let location = try windowPoint(spec["at"] ?? [0.5, 0.5])
            let modifiers = (spec["modifiers"] as? String ?? "").lowercased()
            var flags: CGEventFlags = []
            if modifiers.contains("cmd") { flags.insert(.maskCommand) }
            if modifiers.contains("opt") { flags.insert(.maskAlternate) }
            guard let cgEvent = CGEvent(scrollWheelEvent2Source: nil, units: .line, wheelCount: 1, wheel1: Int32(lines), wheel2: 0, wheel3: 0) else {
                throw Failure("Could not make a scroll event")
            }
            cgEvent.flags = flags
            // The event's location is in screen coordinates, top left origin.
            let screenPoint = window.convertPoint(toScreen: location)
            let screenHeight = NSScreen.screens.first?.frame.height ?? 0
            cgEvent.location = CGPoint(x: screenPoint.x, y: screenHeight - screenPoint.y)
            guard let event = NSEvent(cgEvent: cgEvent) else { throw Failure("Could not make a scroll event") }
            view.scrollWheel(with: event)
        }
        if let factor = spec["magnify"] as? Double {
            let point = try Self.point(spec["at"] ?? [0.5, 0.5]) ?? UnitPoint(x: 0.5, y: 0.5)
            let local = NSPoint(x: point.x * view.pixelSize.width, y: point.y * view.pixelSize.height)
            view.setMagnification(view.magnification * CGFloat(factor), centeredAt: local)
        }
    }

    /// Drags a rubber band in the grid from the gap before one tile to the middle of another,
    /// through the same mouse handlers a person's drag goes through.
    private func dragBand(in grid: PhotoGridController, from first: String, to last: String, modifiers: NSEvent.ModifierFlags) throws {
        guard let session = app.session, let window = windowController?.window,
              let start = session.gridOrder.position(of: first), let end = session.gridOrder.position(of: last)
        else { throw Failure("Both photos must be shown in the grid") }
        let collection = grid.collectionView
        collection.layoutSubtreeIfNeeded()
        guard let layout = collection.collectionViewLayout,
              let a = layout.layoutAttributesForItem(at: IndexPath(item: start, section: 0))?.frame,
              let b = layout.layoutAttributesForItem(at: IndexPath(item: end, section: 0))?.frame
        else { throw Failure("No layout for the tiles") }
        // Just above and left of the first tile, in the gap between tiles.
        let from = NSPoint(x: a.minX - PhotoGridController.spacing / 2, y: a.minY - PhotoGridController.spacing / 2)
        let to = NSPoint(x: b.midX, y: b.midY)
        // Both ends on screen, so the drag does not scroll the grid.
        collection.scrollToVisible(NSRect(x: min(from.x, to.x), y: min(from.y, to.y), width: abs(to.x - from.x), height: abs(to.y - from.y)))
        func event(_ type: NSEvent.EventType, _ point: NSPoint) -> NSEvent? {
            NSEvent.mouseEvent(
                with: type, location: collection.convert(point, to: nil), modifierFlags: modifiers,
                timestamp: ProcessInfo.processInfo.systemUptime, windowNumber: window.windowNumber, context: nil,
                eventNumber: 0, clickCount: 1, pressure: 1
            )
        }
        guard let down = event(.leftMouseDown, from), let drag = event(.leftMouseDragged, to), let up = event(.leftMouseUp, to) else {
            throw Failure("Could not make mouse events")
        }
        collection.mouseDown(with: down)
        collection.mouseDragged(with: drag)
        collection.mouseUp(with: up)
    }

    func resolve(_ path: String, directory: Bool) -> URL {
        var text = path
        if let shootPath { text = text.replacingOccurrences(of: "$SHOOT", with: shootPath) }
        if text.hasPrefix("~/") { text = NSHomeDirectory() + text.dropFirst(1) }
        if text.hasPrefix("/") { return URL(fileURLWithPath: text, isDirectory: directory).standardizedFileURL }
        return scriptURL.deletingLastPathComponent().appendingPathComponent(text, isDirectory: directory).standardizedFileURL
    }

    private func setWindowSize(width: Double, height: Double) {
        guard let window = windowController?.window else { return }
        var frame = window.frame
        frame.origin.y += frame.height - height
        frame.size = NSSize(width: width, height: height)
        window.setFrame(frame, display: true)
    }

    func log(_ text: String) {
        FileHandle.standardError.write(Data("[automation] \(text)\n".utf8))
    }

    func finish(ok: Bool, failedStep: Int?, error: String?) {
        guard !finished else { return }
        finished = true
        var result: [String: Any] = [
            "ok": ok,
            "script": scriptURL.path,
            "output": outputFolder.path,
            "steps": stepResults,
            "elapsedSeconds": (Date().timeIntervalSince(startedAt) * 100).rounded() / 100,
            "longestMainThreadStallMs": (StallMonitor.shared.snapshot().longestMs * 10).rounded() / 10,
        ]
        if let failedStep { result["failedStep"] = failedStep }
        if let error { result["error"] = error }
        if let data = try? JSONSerialization.data(withJSONObject: result, options: [.prettyPrinted, .sortedKeys]) {
            try? data.write(to: outputFolder.appendingPathComponent("result.json"))
        }
        log(ok ? "Finished" : "Failed: \(error ?? "")")
    }

    /// Quits from the run loop rather than from inside this task: `terminate` waits in a nested
    /// run loop for the save flush, which runs on the main queue, and the main queue does not
    /// run while one of its own jobs (this task) is still on the stack.
    private func quit() {
        // A sheet or alert left open would stop the app from quitting.
        app.problem = nil
        if let window = windowController?.window {
            for sheet in window.sheets { window.endSheet(sheet) }
        }
        if NSApp.modalWindow != nil { NSApp.abortModal() }
        RunLoop.main.perform(inModes: [.default, .modalPanel]) {
            MainActor.assumeIsolated { NSApp.terminate(nil) }
        }
    }

    /// Ends the process if the script runs too long, even when the main thread is stuck.
    private func startWatchdog(seconds: Double) {
        let resultURL = outputFolder.appendingPathComponent("result.json")
        let script = scriptURL.path
        DispatchQueue.global(qos: .utility).asyncAfter(deadline: .now() + seconds) {
            let result: [String: Any] = [
                "ok": false, "script": script, "error": "Timed out after \(Int(seconds)) s (watchdog)",
            ]
            if let data = try? JSONSerialization.data(withJSONObject: result, options: [.prettyPrinted]) {
                try? data.write(to: resultURL)
            }
            FileHandle.standardError.write(Data("[automation] Watchdog: timed out after \(Int(seconds)) s\n".utf8))
            _exit(3)
        }
    }
}
#endif
