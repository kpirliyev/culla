#if DEBUG
import AppKit
import CullaCommands
import CullaSession
import Foundation

/// Steps for performance measurements, loops, the accessibility tree and the windows of the
/// Help and Culla menus. See Scripts/README.md.
extension AutomationRunner {
    static let extraActions = [
        "record", "expectAtMost", "dragSlider", "loop", "accessibility", "keyboardFocus", "window", "firstRun",
        "scanToggle", "systemAccessibility", "updates",
    ]

    /// Runs one of the steps above, or returns nil when the action is not one of them.
    func performExtraStep(_ action: String, _ step: [String: Any]) async throws -> String? {
        switch action {
        case "record":
            // {"record": "open", "values": {"shownMs": "open.shownMs"}}: the stall window since the
            // last resetStalls, memory now and at peak, and any dump values named, kept under
            // `measurements.<name>` in every later dump.
            guard let name = step["record"] as? String else { throw Failure("\"record\" needs a name") }
            let stall = StallMonitor.shared.snapshot()
            let memory = MemoryUsage.current()
            var entry: [String: Any] = [
                "longestStallMs": Self.round1(stall.windowLongestMs),
                "stallsOver50": stall.windowOver50,
                "stallsOver100": stall.windowOver100,
                "seconds": Self.round1(Date().timeIntervalSince(stallWindowStartedAt)),
                "footprintMB": Self.round1(Double(memory.footprintBytes) / 1_048_576),
                "peakFootprintMB": Self.round1(Double(memory.peakFootprintBytes) / 1_048_576),
            ]
            if let values = step["values"] as? [String: String] {
                let state = makeDump(includePhotos: false, listing: nil)
                for (key, path) in values { entry[key] = StateDump.value(at: path, in: state) ?? NSNull() }
            }
            measurements[name] = entry
            return entry.keys.sorted().map { "\($0) \(StateDump.text(entry[$0]))" }.joined(separator: ", ")

        case "expectAtMost":
            // {"expectAtMost": {"measurements.open.longestStallMs": 100}}: fails when a number is larger.
            guard let limits = step["expectAtMost"] as? [String: Double] else { throw Failure("\"expectAtMost\" needs an object of numbers") }
            let state = makeDump(includePhotos: false, listing: nil)
            var over: [String] = []
            for (path, limit) in limits.sorted(by: { $0.key < $1.key }) {
                let raw = StateDump.value(at: path, in: state)
                guard let value = (raw as? CGFloat).map(Double.init) ?? (raw as? Double) ?? (raw as? Int).map(Double.init) else {
                    over.append("\(path): no number")
                    continue
                }
                if value > limit { over.append("\(path): \(value) is over \(limit)") }
            }
            if !over.isEmpty { throw Failure(over.joined(separator: "; ")) }
            return "\(limits.count) limits"

        case "dragSlider":
            // {"dragSlider": "blurryBelow", "from": 10, "to": 40, "steps": 40, "interval": 0.016, "in": "settings"}
            // Moves a detection slider in small steps, as a drag does: in Settings (the default
            // tuning) or in the tuning panel (`"in": "panel"`, this shoot's tuning).
            guard let name = step["dragSlider"] as? String, let key = TuningKey(rawValue: name) else {
                throw Failure("\"dragSlider\" needs a TuningKey")
            }
            guard let from = step["from"] as? Double, let to = step["to"] as? Double else { throw Failure("\"dragSlider\" needs \"from\" and \"to\"") }
            let count = max(1, step["steps"] as? Int ?? 30)
            let interval = step["interval"] as? Double ?? 0.016
            let inPanel = step["in"] as? String == "panel"
            let settings = inPanel ? nil : try settingsModel()
            guard inPanel ? app.session != nil : true else { throw Failure("No shoot is open") }
            let control = TuningControl.control(for: key)
            for index in 0...count {
                let value = control.snapped(from + (to - from) * Double(index) / Double(count))
                if let settings {
                    settings.setValue(key, value)
                } else {
                    app.session?.setTuningValue(key, value)
                }
                try await Task.sleep(for: .milliseconds(Int(interval * 1000)))
            }
            return "\(name) \(from) → \(to) in \(count) steps"

        case "loop":
            // {"loop": 20, "steps": [...]}: runs the steps that many times.
            guard let times = step["loop"] as? Int, let steps = step["steps"] as? [[String: Any]] else {
                throw Failure("\"loop\" needs a count and \"steps\"")
            }
            for round in 0..<times {
                for (index, inner) in steps.enumerated() {
                    let action = Self.action(of: inner)
                    let beganAt = Self.round1(StallMonitor.shared.now())
                    do {
                        _ = try await perform(action, inner)
                        loopSteps.append(["round": round, "index": index, "action": action, "atMs": beganAt,
                                          "what": StateDump.text(inner[action])])
                        if loopSteps.count > 2000 { loopSteps.removeFirst() }
                    } catch {
                        throw Failure("round \(round), step \(index) (\(action)): \(error)")
                    }
                }
            }
            return "\(times) rounds of \(steps.count) steps"

        case "accessibility":
            return try await accessibilityStep(step)

        case "updates":
            return try await updateStep(step)

        case "window":
            // {"window": "about"} or "help" (the keyboard cheat sheet), "docs" (records the docs
            // folder Help would open), "close": shows a window of the Culla and Help menus.
            guard let name = step["window"] as? String else { throw Failure("\"window\" needs a name") }
            guard let show = showAuxiliaryWindow else { throw Failure("No window handler") }
            let detail = try show(name)
            try await Task.sleep(for: .milliseconds(200))
            return detail

        case "firstRun":
            // {"firstRun": "dismiss"} dismisses the welcome view's introduction; "reset" shows it again.
            switch step["firstRun"] as? String {
            case "dismiss": app.dismissIntroduction()
            case "reset": app.settings.introductionDismissed = false
            default: throw Failure("\"firstRun\" is dismiss or reset")
            }
            try await Task.sleep(for: .milliseconds(60))
            return step["firstRun"] as? String

        case "scanToggle":
            // {"scanToggle": "includeSubfolders", "value": false}: flips a setting that rescans,
            // through the confirmation the Settings window shows; then {"scanToggle": "confirm"}
            // or "cancel" answers it.
            let model = try settingsModel()
            switch step["scanToggle"] as? String {
            case "confirm":
                guard model.pendingScanChange != nil else { throw Failure("No confirmation is shown") }
                model.confirmScanChange()
            case "cancel":
                guard model.pendingScanChange != nil else { throw Failure("No confirmation is shown") }
                model.cancelScanChange()
            case let name?:
                guard let option = SettingsModel.ScanOption(rawValue: name), let value = step["value"] as? Bool else {
                    throw Failure("\"scanToggle\" is includeSubfolders or pairRAWWithRendered with a \"value\", or confirm or cancel")
                }
                await model.requestScanChange(option, to: value)
            default:
                throw Failure("\"scanToggle\" needs a setting")
            }
            try await Task.sleep(for: .milliseconds(80))
            return model.pendingScanChange?.question ?? "applied"

        case "systemAccessibility":
            // {"systemAccessibility": {"increaseContrast": true, "reduceMotion": true, "differentiateWithoutColor": true}}
            // stands in for the system settings (null follows the system again).
            guard let values = step["systemAccessibility"] as? [String: Any] else { throw Failure("\"systemAccessibility\" needs an object") }
            if values.keys.contains("increaseContrast") { SystemAccessibility.overrideIncreaseContrast = values["increaseContrast"] as? Bool }
            if values.keys.contains("reduceMotion") { SystemAccessibility.overrideReduceMotion = values["reduceMotion"] as? Bool }
            if values.keys.contains("differentiateWithoutColor") {
                SystemAccessibility.overrideDifferentiateWithoutColor = values["differentiateWithoutColor"] as? Bool
            }
            SystemAccessibility.notifyChanged()
            try await Task.sleep(for: .milliseconds(150))
            return values.keys.sorted().joined(separator: ", ")

        case "keyboardFocus":
            // {"keyboardFocus": "next", "repeat": 3, "window": "settings"}: moves the key view as Tab
            // does with full keyboard access on; the dump's `keyboardFocus` says where it is.
            let window: NSWindow?
            if step["window"] as? String == "settings" {
                window = settingsController?()?.window
            } else {
                window = windowController?.window
            }
            guard let window else { throw Failure("No such window") }
            let count = max(1, step["repeat"] as? Int ?? 1)
            for _ in 0..<count {
                switch step["keyboardFocus"] as? String {
                case "next": window.selectNextKeyView(nil)
                case "previous": window.selectPreviousKeyView(nil)
                default: throw Failure("\"keyboardFocus\" is next or previous")
                }
                try await Task.sleep(for: .milliseconds(40))
            }
            return Self.describeResponder(window.firstResponder)

        default:
            return nil
        }
    }

    /// Everything the extra steps add to a dump.
    func addExtraState(to state: inout [String: Any]) {
        if !measurements.isEmpty { state["measurements"] = measurements }
        if !loopSteps.isEmpty { state["loopSteps"] = loopSteps }
        let started = StallMonitor.shared.startedAtMediaTime
        state["slowSections"] = MainThreadTiming.sections.suffix(120).map {
            ["name": $0.name, "ms": Self.round1($0.ms), "atMs": Self.round1(($0.at - started) * 1000)] as [String: Any]
        }
        state["introductionShown"] = app.showsIntroduction
        addUpdateState(to: &state)
        state["systemAccessibility"] = [
            "increaseContrast": SystemAccessibility.increaseContrast,
            "reduceMotion": SystemAccessibility.reduceMotion,
            "differentiateWithoutColor": SystemAccessibility.differentiateWithoutColor,
        ]
        if let windows = auxiliaryWindows?() {
            var shown: [String: Any] = [:]
            for (name, window) in windows { shown[name] = ["visible": window.isVisible, "title": window.title] as [String: Any] }
            state["auxiliaryWindows"] = shown
        }
        if let note = auxiliaryNote?() { state["auxiliary"] = note }
        if let window = windowController?.window {
            state["keyboardFocus"] = Self.describeResponder(window.firstResponder)
        }
        state["fullKeyboardAccess"] = NSApp.isFullKeyboardAccessEnabled
        if let shoot = windowController?.shootController {
            state["splitWidths"] = shoot.splitWidths
        }
        if let settings = existingSettingsController?(), settings.isShown, var window = state["settingsWindow"] as? [String: Any] {
            window["keyboardFocus"] = Self.describeResponder(settings.window?.firstResponder)
            window["scrolls"] = settings.model.scrollingPanes.contains(settings.model.pane)
            if let pending = settings.model.pendingScanChange {
                window["scanConfirmation"] = ["question": pending.question, "detail": pending.detail] as [String: Any]
            }
            state["settingsWindow"] = window
        }
    }

    static func describeResponder(_ responder: NSResponder?) -> String {
        guard let responder else { return "none" }
        if let view = responder as? NSView {
            let label = view.accessibilityLabel() ?? view.accessibilityTitle() ?? ""
            return "\(type(of: view))\(label.isEmpty ? "" : " “\(label)”")"
        }
        return String(describing: type(of: responder))
    }

    static func round1(_ value: Double) -> Double {
        (value * 10).rounded() / 10
    }
}
#endif
