#if DEBUG
import AppKit
import CullaAnalysis
import CullaCommands
import CullaCore
import CullaSession
import Foundation

/// The app's state as JSON, for automation scripts to check: what the window shows, the
/// session's totals and groups, the view state, every photo's decision and rating, undo and
/// redo, the longest main-thread stall and memory use.
@MainActor
enum StateDump {
    static func make(app: AppModel, windowController: MainWindowController?, includePhotos: Bool, listing: [String: Any]? = nil) -> [String: Any] {
        var dump: [String: Any] = [:]
        switch app.screen {
        case .welcome: dump["screen"] = "welcome"
        case .loading: dump["screen"] = "loading"
        case .shoot: dump["screen"] = "shoot"
        }
        let stall = StallMonitor.shared.snapshot()
        dump["stall"] = [
            "longestMs": round1(stall.longestMs),
            "windowLongestMs": round1(stall.windowLongestMs),
            "windowOver50": stall.windowOver50,
            "windowOver100": stall.windowOver100,
            "over50": stall.events.map { ["atMs": round1($0.atMs), "ms": round1($0.ms)] },
        ]
        dump["longestMainThreadStallMs"] = round1(stall.longestMs)
        let memory = MemoryUsage.current()
        dump["memory"] = [
            "residentMB": round1(Double(memory.residentBytes) / 1_048_576),
            "footprintMB": round1(Double(memory.footprintBytes) / 1_048_576),
            "peakFootprintMB": round1(Double(memory.peakFootprintBytes) / 1_048_576),
        ]
        dump["power"] = ["onBattery": app.power.onBattery, "memoryPressure": app.power.memoryPressure.rawValue,
                         "reduceAnalysisOnBattery": app.settings.reduceAnalysisOnBattery]
        dump["activity"] = app.activity.summary
        dump["recents"] = app.recents.map { ["name": $0.name, "photos": $0.counts?.photos ?? 0] as [String: Any] }
        if let problem = app.problem {
            dump["problem"] = ["title": problem.title, "message": problem.message]
        }
        if let timings = app.lastOpenTimings {
            var open: [String: Any] = ["photoCount": timings.photoCount, "metadataRead": timings.metadataRead]
            if let known = timings.photosKnownAt { open["photosKnownMs"] = round1(known.timeIntervalSince(timings.startedAt) * 1000) }
            if let shown = timings.shownAt { open["shownMs"] = round1(shown.timeIntervalSince(timings.startedAt) * 1000) }
            dump["open"] = open
        }
        if let window = windowController?.window {
            dump["window"] = [
                "width": window.frame.width, "height": window.frame.height,
                "title": window.title, "subtitle": window.subtitle,
                "isKey": window.isKeyWindow, "appActive": NSApp.isActive,
            ] as [String: Any]
        }

        guard let session = app.session else { return dump }
        let state = session.state
        let totals = state.totals
        dump["folder"] = session.name
        dump["totals"] = [
            "photos": totals.photos, "kept": totals.kept, "rejected": totals.rejected,
            "left": totals.left, "unreadable": totals.unreadable,
        ]
        var groups: [String: Any] = [:]
        for group in GroupID.allCases {
            let count = state.count(of: group)
            groups[group.rawValue] = ["left": count.left, "total": count.total]
        }
        dump["groups"] = groups
        dump["currentGroup"] = session.group.rawValue
        dump["viewMode"] = session.viewMode.rawValue
        dump["focus"] = session.focus ?? NSNull()
        let selection = session.selection.selected.compactMap { id in session.order.position(of: id).map { (id, $0) } }
            .sorted { $0.1 < $1.1 }.map(\.0)
        dump["selection"] = selection
        dump["selectionCount"] = session.selection.selected.count
        dump["targets"] = session.targets
        dump["visibleCount"] = session.order.count
        dump["focusPosition"] = session.focus.flatMap { session.order.position(of: $0) } ?? NSNull()
        dump["inspectorVisible"] = session.inspectorVisible
        dump["thumbnailSize"] = app.settings.thumbnailSize
        dump["advanceAfterDecision"] = app.settings.advanceAfterDecision
        dump["gridColumns"] = session.gridColumns
        dump["canUndo"] = state.canUndo
        dump["canRedo"] = state.canRedo
        dump["undoTitle"] = session.undoTitle
        dump["redoTitle"] = session.redoTitle
        dump["pendingSaves"] = session.saver.pending
        dump["saveError"] = session.saver.lastError ?? NSNull()
        dump["folderMissing"] = session.folderMissing
        dump["thumbnailsAwaitingFolder"] = session.thumbnailsAwaitingFolder.count
        dump["apply"] = session.apply.dumpState
        var disk: [String: Any] = [
            "disconnected": session.folderMissing,
            "readOnly": session.apply.isReadOnly,
            "rescan": session.disk.dumpState,
            "undoApplyRequest": session.undoApplyRequest?.question ?? NSNull(),
        ]
        if let listing { disk["listing"] = listing }
        dump["disk"] = disk
        if let shoot = windowController?.shootController {
            let notice = shoot.photoArea.noticeHost
            dump["noticeBar"] = ["height": Double(notice?.frame.height ?? 0), "top": Double(notice?.frame.minY ?? 0)]
            dump["applyScreenShown"] = shoot.applyHost.map { !$0.isHidden } ?? false
        }
        if let merge = session.mergeResult {
            dump["merge"] = ["added": merge.added, "removed": merge.removed, "modified": merge.modified]
        }
        if let shoot = windowController?.shootController {
            dump["visibleTilesWithoutImage"] = shoot.photoArea.grid.visibleTilesWithoutImage
            if let loupe = shoot.photoArea.loupe {
                dump["loupe"] = loupe.dumpState()
                if session.viewMode == .loupe, !loupe.faceStrip.isHidden { dump["faceStrip"] = loupe.faceStrip.dumpState() }
            }
            if let review = shoot.photoArea.stackReview {
                dump["stackReview"] = review.dumpState()
                if session.viewMode == .stackReview, !review.strip.isHidden { dump["faceStrip"] = review.strip.dumpState() }
            }
            if let review = shoot.photoArea.duplicateReview {
                dump["duplicates"] = review.dumpState()
            }
            if let compare = shoot.photoArea.compare, session.viewMode == .compare {
                dump["compare"] = compare.dumpState()
            }
        }
        dump["stacksExpanded"] = session.stacksExpanded
        dump["stacksLeft"] = state.stackCounts.left
        dump["exactSetsLeft"] = state.duplicateSetCounts(kind: .exact).left
        dump["nearSetsLeft"] = state.duplicateSetCounts(kind: .near).left
        let edits = state.stackEdits
        dump["stackEdits"] = ["joined": edits.joined, "splitOut": edits.splitOut.sorted(), "bestPicks": edits.bestPicks.sorted()]
        if let entries = session.gridEntries {
            dump["gridEntries"] = entries.entries.prefix(400).map { entry -> [String: Any] in
                switch entry {
                case .photo(let id):
                    return ["kind": "photo", "id": id]
                case .stack(let stack):
                    return [
                        "kind": "stack", "id": stack.id, "representative": stack.representative, "frameCount": stack.frameCount,
                        "isBestPick": stack.representativeIsBestPick,
                        "decisions": ["unreviewed": stack.decisions.unreviewed, "kept": stack.decisions.kept, "rejected": stack.decisions.rejected],
                        "summary": stack.decisions.uniform?.rawValue ?? "mixed",
                    ]
                }
            }
            dump["gridEntryCount"] = entries.count
        }
        dump["gridOrder"] = session.gridOrder.count <= 400 ? session.gridOrder.ids : Array(session.gridOrder.ids.prefix(400))
        dump["collapsedTargets"] = session.collapsedTargets
        dump["lastFileAction"] = session.lastFileAction ?? NSNull()
        if let analysis = session.analysis {
            dump["analysis"] = analysisState(analysis, app: app)
        }
        dump["stacks"] = state.stacks.map { ["members": $0.members, "bestPick": $0.bestPick ?? NSNull()] as [String: Any] }
        dump["duplicateSets"] = state.duplicateSets.map { ["kind": $0.kind.rawValue, "members": $0.members] as [String: Any] }
        dump["stackCount"] = state.stacks.count
        dump["exactDuplicateSets"] = state.duplicateSets.filter { $0.kind == .exact }.count
        dump["nearDuplicateSets"] = state.duplicateSets.filter { $0.kind == .near }.count
        dump["pinnedScores"] = session.pinnedScoreIDs.sorted()
        dump["emptyReason"] = session.order.isEmpty ? String(describing: session.emptyReason) : NSNull()
        dump["summaryBanner"] = session.summaryBanner.map { AnalysisText.summary($0) } ?? NSNull()
        dump["notice"] = session.notice?.text ?? NSNull()
        dump["completedGroup"] = session.completedGroup?.rawValue ?? NSNull()
        dump["nextGroupToReview"] = session.nextGroupToReview?.rawValue ?? NSNull()
        dump["confirmation"] = windowController?.shootController?.confirmation?.messageText ?? NSNull()
        dump["lastBulkRejectQuestion"] = session.lastBulkRejectQuestion ?? NSNull()
        dump["certainLeft"] = state.undecidedCertainMembers(of: session.group).count
        var tuning: [String: Any] = [:]
        for key in TuningKey.allCases { tuning[key.rawValue] = key.value(in: state.tuning) }
        dump["tuning"] = tuning
        // Photos per flag, any tier: lets scripts check flags that do not hang on a borderline
        // detector reading (such as Vision's lens smudge) without the totals that do.
        dump["flagCounts"] = TuningCounts(state).flagCountsByName
        dump["tuningScope"] = [
            "hasOwnTuning": session.hasOwnTuning,
            "differsFromDefault": TuningKey.allCases.filter { $0.value(in: state.tuning) != $0.value(in: app.settings.defaultTuning) }.map(\.rawValue),
            "preset": TuningPreset.matching(state.tuning)?.rawValue ?? "custom",
        ] as [String: Any]
        if let group = session.tuningPanelGroup {
            let counts = TuningCounts(state)
            let baseline = session.tuningBaseline
            dump["tuningPanel"] = [
                "group": group.rawValue,
                "shown": windowController?.shootController?.photoArea.tuningPopover?.isShown ?? false,
                "groupTotal": [session.tuningBaselineTotal, state.count(of: group).total],
                "lines": TuningControl.controls(for: group).map { control -> String in
                    if control.isOff(in: state.tuning) { return "\(control.countName): off" }
                    guard let counted = control.counted else { return "" }
                    return control.countLine(before: baseline.count(counted), after: counts.count(counted))
                },
                "hasOwnTuning": session.hasOwnTuning,
            ] as [String: Any]
        }
        if includePhotos {
            var members: [String: Any] = [:]
            for group in GroupID.allCases where group != .allPhotos {
                members[group.rawValue] = state.members(of: group)
            }
            dump["groupMembers"] = members
        }
        dump["screenPreviewsHeld"] = session.previews.count
        dump["thumbnailMemoryMB"] = round1(Double(session.thumbnails.memoryUsage) / 1_048_576)
        if includePhotos {
            dump["photos"] = state.photos.map { item -> [String: Any] in
                var entry: [String: Any] = ["id": item.id, "decision": item.decision.rawValue, "rating": item.rating]
                if let summary = state.summary(for: item.id) {
                    entry["flags"] = summary.flags.map(\.rawValue).sorted()
                    entry["tiers"] = Dictionary(uniqueKeysWithValues: summary.tiers.map { ($0.key.rawValue, $0.value.rawValue) })
                    entry["mainFaces"] = summary.mainFaces
                }
                entry["hasScores"] = item.scores != nil
                if item.isNew { entry["isNew"] = true }
                if item.isUnreadable { entry["unreadable"] = item.unreadableReason ?? true }
                if !item.file.companions.isEmpty { entry["companions"] = item.file.companions.map(\.lastPathComponent) }
                return entry
            }
        }
        return dump
    }

    private static func analysisState(_ analysis: AnalysisController, app: AppModel) -> [String: Any] {
        let progress = analysis.progress
        var state: [String: Any] = [
            "phase": analysis.phase.rawValue,
            "done": progress.done,
            "total": progress.total,
            "running": progress.running,
            "cached": progress.cached,
            "unreadable": progress.unreadable,
            "isPaused": progress.isPaused,
            "photosPerSecond": progress.photosPerSecond.map { round1($0) } ?? NSNull(),
            "secondsRemaining": progress.secondsRemaining.map { round1($0) } ?? NSNull(),
            "concurrency": analysis.concurrency,
            "concurrencyReason": analysis.concurrencyReason,
            "analysedThisOpen": analysis.analysedThisOpen,
            "cachedCount": analysis.cachedCount,
            "groupingsApplied": analysis.groupingsApplied,
            "groupingPending": analysis.groupingPending,
            "events": analysis.eventCounts,
            "statusText": analysis.statusText,
        ]
        var timings: [String: Any] = [:]
        let marks: [(String, Date?)] = [
            ("shown", app.lastOpenTimings?.shownAt), ("started", analysis.startedAt), ("cachedApplied", analysis.cachedAppliedAt),
            ("firstResult", analysis.firstResultAt), ("firstGroupCount", analysis.firstGroupCountAt),
            ("firstGrouping", analysis.firstGroupingAt), ("finished", analysis.finishedAt),
        ]
        for (name, date) in marks {
            if let seconds = analysis.seconds(date) { timings[name + "S"] = seconds }
        }
        state["timings"] = timings
        // Photos per second over the whole run in this open, from the first result to the end.
        if let first = analysis.startedAt, analysis.analysedThisOpen > 0 {
            let end = analysis.finishedAt ?? Date()
            let seconds = end.timeIntervalSince(first)
            if seconds > 0 { state["overallPhotosPerSecond"] = round1(Double(analysis.analysedThisOpen) / seconds) }
        }
        return state
    }

    private static func round1(_ value: Double) -> Double {
        (value * 10).rounded() / 10
    }

    // MARK: - Expectations

    /// The value at a dotted path, such as "totals.kept" or "groups.kept.total". A segment
    /// "photo:<id>" picks a photo from the "photos" list, such as "photo:a.jpg.decision" — the
    /// id runs up to the last dot.
    static func value(at path: String, in dump: [String: Any]) -> Any? {
        if path.hasPrefix("photo:") {
            // The id is the longest photo id the rest starts with, followed by a dot; what
            // follows is a key, or a dotted path into the photo ("tiers.blurry").
            let rest = String(path.dropFirst("photo:".count))
            let photos = dump["photos"] as? [[String: Any]] ?? []
            let matches = photos.filter { photo in
                guard let id = photo["id"] as? String else { return false }
                return rest.hasPrefix(id + ".")
            }
            guard let photo = matches.max(by: { ($0["id"] as? String ?? "").count < ($1["id"] as? String ?? "").count }),
                  let id = photo["id"] as? String
            else { return nil }
            let key = String(rest.dropFirst(id.count + 1))
            switch key {
            case "isNew": return photo["isNew"] ?? false
            case "unreadable": return photo["unreadable"] != nil
            default:
                if photo[key] != nil || !key.contains(".") { return photo[key] }
                return value(at: key, in: photo)
            }
        }
        var current: Any? = dump
        for segment in path.split(separator: ".") {
            if let object = current as? [String: Any] {
                current = object[String(segment)]
            } else if let list = current as? [Any], let index = Int(segment), list.indices.contains(index) {
                current = list[index]
            } else if segment == "count", let list = current as? [Any] {
                current = list.count
            } else {
                return nil
            }
        }
        return current
    }

    /// Values are equal when their JSON text is; with a tolerance, numbers (alone or in lists)
    /// may differ by that much.
    static func equal(_ actual: Any?, _ expected: Any, tolerance: Double = 0) -> Bool {
        if tolerance > 0 {
            if let a = actual as? Double, let e = expected as? Double, !(actual is Bool), !(expected is Bool) {
                return abs(a - e) <= tolerance
            }
            if let a = actual as? [Any], let e = expected as? [Any], a.count == e.count {
                return zip(a, e).allSatisfy { equal($0, $1, tolerance: tolerance) }
            }
        }
        return text(actual) == text(expected)
    }

    static func text(_ value: Any?) -> String {
        guard let value, !(value is NSNull) else { return "null" }
        if let data = try? JSONSerialization.data(withJSONObject: value, options: [.fragmentsAllowed, .sortedKeys]),
           let text = String(data: data, encoding: .utf8) {
            return text
        }
        return String(describing: value)
    }
}

extension StateDump {
    /// The menu bar as it would show now: every menu's title and its items' titles, with
    /// submenus nested (`items`), separators left out. Titles that change with the state (Undo,
    /// Open Recent) are brought up to date first, as opening the menu would.
    static func mainMenuTree() -> [[String: Any]] {
        guard let menu = NSApp.mainMenu else { return [] }
        return menuItems(menu)
    }

    private static func menuItems(_ menu: NSMenu) -> [[String: Any]] {
        menu.delegate?.menuNeedsUpdate?(menu)
        menu.update()
        return menu.items.filter { !$0.isSeparatorItem && !$0.isHidden }.map { item in
            var entry: [String: Any] = ["title": item.title]
            if !item.keyEquivalent.isEmpty { entry["key"] = item.keyEquivalent }
            // The Services menu's items are the system's, not Culla's.
            if let submenu = item.submenu, submenu !== NSApp.servicesMenu {
                // The app menu's own title is the app's name; its menu bar title is the submenu's.
                if item.title.isEmpty { entry["title"] = submenu.title }
                entry["items"] = menuItems(submenu)
            }
            return entry
        }
    }

    /// The settings in effect, the default tuning beside the shoot's, the key map with its
    /// conflicts and the keys the menus show, the cache, and the Settings window's state.
    static func addSettings(to dump: inout [String: Any], app: AppModel, settings window: SettingsWindowController?, menuKeys: [String: String]) {
        let settings = app.settings
        let mapping = settings.sidecarMapping
        dump["settings"] = [
            "advanceAfterDecision": settings.advanceAfterDecision,
            "includeSubfolders": settings.includeSubfolders,
            "pairRAWWithRendered": settings.pairRAWWithRendered,
            "collapseStacksInAllPhotos": settings.collapseStacksInAllPhotos,
            "showsBestPickPane": settings.showsBestPickPane,
            "reduceAnalysisOnBattery": settings.reduceAnalysisOnBattery,
            "cacheLimitGB": settings.cacheLimitGB,
            "rejectAction": settings.rejectAction.rawValue,
            "writeSidecars": settings.writeSidecars,
            "sidecarMapping": [
                "writesRating": mapping.writesRating, "rejectedRating": mapping.rejectedRating ?? NSNull(),
                "keptLabel": mapping.keptLabel ?? NSNull(), "rejectedLabel": mapping.rejectedLabel ?? NSNull(),
            ] as [String: Any],
            "editorApplication": settings.editorApplication?.path ?? NSNull(),
            "language": settings.language?.rawValue ?? "system",
            "checksForUpdatesAutomatically": settings.checksForUpdatesAutomatically,
        ] as [String: Any]
        // The language the app runs in, and the choice it was launched with.
        dump["language"] = [
            "running": Localization.language.rawValue,
            "preferredLocalizations": Bundle.main.preferredLocalizations,
            "localizations": Bundle.main.localizations,
            "launchChoice": settings.launchChoice?.rawValue ?? "system",
            "reopenOffered": settings.language != settings.launchChoice,
            "quitAndReopenRequested": app.quitAndReopenRequested,
        ] as [String: Any]
        dump["mainMenu"] = mainMenuTree()
        var defaults: [String: Any] = [:]
        for key in TuningKey.allCases { defaults[key.rawValue] = key.value(in: settings.defaultTuning) }
        dump["tuningDefault"] = defaults
        dump["preset"] = TuningPreset.matching(settings.defaultTuning)?.rawValue ?? "custom"
        let keys = settings.keyBindings
        dump["keyMap"] = Dictionary(uniqueKeysWithValues: Command.allCases.map { ($0.rawValue, keys.chords(for: $0).map(\.description)) })
        dump["keyConflicts"] = keys.conflicts.map(\.message)
        dump["menuKeys"] = menuKeys
        if let usage = app.cacheUsage {
            dump["cache"] = [
                "thumbnailBytes": usage.thumbnailBytes, "cachedScores": usage.cachedScores,
                "databaseBytes": usage.databaseBytes, "limitBytes": settings.cacheLimitBytes,
            ] as [String: Any]
        }
        guard let window else {
            dump["settingsWindow"] = ["shown": false]
            return
        }
        let model = window.model
        var state: [String: Any] = [
            "shown": window.isShown,
            "pane": model.pane.rawValue,
            "title": window.window?.title ?? "",
            "recording": model.recording?.rawValue ?? NSNull(),
            "conflict": model.pendingConflict?.message ?? NSNull(),
        ]
        if model.pane.tuningPane != nil {
            state["scopeNote"] = model.scopeNote
            state["lines"] = model.dumpLines
            state["preset"] = model.preset?.rawValue ?? "custom"
        }
        if model.pane == .performance {
            let info = model.concurrency
            state["concurrency"] = ["count": info.count, "explanation": info.explanation] as [String: Any]
        }
        if let frame = window.window?.frame { state["size"] = [frame.width, frame.height] }
        dump["settingsWindow"] = state
    }
}
#endif
