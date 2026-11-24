import AppKit
import CullaAnalysis
import CullaCommands
import CullaCore
import CullaPipeline
import Foundation
import Observation

/// The panes of the Settings window, in the Design doc's order.
enum SettingsPane: String, CaseIterable, Identifiable {
    case general
    case eyes
    case blur
    case similarity
    case duplicates
    case exposure
    case other
    case performance
    case keys

    var id: String { rawValue }

    var title: String {
        switch self {
        case .general: localized("settings.pane.general", default: "General")
        case .performance: localized("settings.pane.performance", default: "Performance")
        case .keys: localized("settings.pane.keys", default: "Keys")
        default: tuningPane!.title
        }
    }

    var symbol: String {
        switch self {
        case .general: "gearshape"
        case .eyes: "eye"
        case .blur: "camera.aperture"
        case .similarity: "square.stack.3d.up"
        case .duplicates: "plus.square.on.square"
        case .exposure: "sun.max"
        case .other: "exclamationmark.triangle"
        case .performance: "gauge.with.dots.needle.67percent"
        case .keys: "keyboard"
        }
    }

    /// The detection pane it shows, for the six detection panes.
    var tuningPane: TuningPane? {
        switch self {
        case .eyes: .eyes
        case .blur: .blur
        case .similarity: .similarity
        case .duplicates: .duplicates
        case .exposure: .exposure
        case .other: .other
        case .general, .performance, .keys: nil
        }
    }
}

/// What the Settings window shows and does, shared by its views and the automation harness, so
/// a script changes settings exactly the way the window does.
///
/// Detection panes edit the default tuning (`AppSettings.defaultTuning`). The open shoot follows
/// it at once unless it was adjusted from its own tuning panel; the panes then say so, offer to
/// put the shoot back on the default, and count what the default would flag in it.
@MainActor
@Observable
final class SettingsModel {
    let app: AppModel
    var settings: AppSettings { app.settings }
    /// The Settings window, for the alert Check Now answers with; set by its controller.
    @ObservationIgnored weak var window: NSWindow?

    /// The pane on screen.
    var pane: SettingsPane = .general {
        didSet { if pane != oldValue { takeBaseline() } }
    }

    /// The counts when the pane was opened, so count lines can say "41 → 28".
    @ObservationIgnored private var baseline: (sessionID: Int64, counts: TuningCounts)?

    // MARK: Keys

    /// The command whose key is being recorded, if any.
    private(set) var recording: Command?
    /// Which of its keys the recorded one replaces; nil adds a key, keeping the others.
    private(set) var recordingChord: KeyChord?
    /// True while recording adds a key rather than replacing one.
    private(set) var recordingAdds = false

    /// Panes too tall for the screen, shown in a scrolling form at a capped height.
    var scrollingPanes: Set<SettingsPane> = []
    /// The height those panes are shown at, so the window keeps it as the pane's ideal size.
    var scrollingHeight: CGFloat = 620

    // MARK: Rescans

    /// The two settings that scan the open shoot again and can drop photos from it.
    enum ScanOption: String {
        case includeSubfolders
        case pairRAWWithRendered
    }

    /// A rescanning change waiting for the person to confirm it, with what it would cost.
    struct ScanChange: Equatable {
        var option: ScanOption
        var value: Bool
        var leaving: Int
        var leavingDecided: Int
        var question: String
        var detail: String
        var buttonTitle: String
    }

    private(set) var pendingScanChange: ScanChange?
    /// A chord pressed for `recording` that another command already sends, or that is fixed.
    private(set) var pendingConflict: KeyConflict?
    @ObservationIgnored private var pendingChord: KeyChord?

    init(app: AppModel) {
        self.app = app
    }

    // MARK: - Detection

    var defaultTuning: Tuning { settings.defaultTuning }

    /// The preset the default's sliders match, or nil for Custom.
    var preset: TuningPreset? { TuningPreset.matching(settings.defaultTuning) }

    func applyPreset(_ preset: TuningPreset) {
        settings.defaultTuning = preset.applied(to: settings.defaultTuning)
    }

    func value(_ key: TuningKey) -> Double {
        key.value(in: settings.defaultTuning)
    }

    func setValue(_ key: TuningKey, _ value: Double) {
        var tuning = settings.defaultTuning
        key.set(TuningControl.control(for: key).snapped(value), in: &tuning)
        settings.defaultTuning = tuning
    }

    /// A pane's values back to Balanced.
    func resetPane(_ pane: TuningPane) {
        settings.defaultTuning = pane.resetting(settings.defaultTuning)
    }

    func paneIsAtBalanced(_ pane: TuningPane) -> Bool {
        pane.resetting(settings.defaultTuning) == settings.defaultTuning
    }

    /// What the pane's counts are about, in one line.
    enum Scope: Equatable {
        case noShoot
        /// The open shoot follows the default: changes show in it at once.
        case follows(name: String)
        /// The open shoot was adjusted from its own tuning panel.
        case ownTuning(name: String)
    }

    var scope: Scope {
        guard let session = app.session else { return .noShoot }
        return session.hasOwnTuning ? .ownTuning(name: session.name) : .follows(name: session.name)
    }

    var scopeNote: String {
        switch scope {
        case .noShoot:
            return localized("Open a shoot to see how many of its photos each setting flags.")
        case .follows(let name):
            return localized("Defaults for every shoot. “\(name)” uses them, and the counts are from it.")
        case .ownTuning(let name):
            return localized("“\(name)” has its own settings from its Adjust panel, so changes here apply to other shoots. Counts show what these would flag in it.")
        }
    }

    /// The open shoot goes back to following the default.
    func useDefaultForOpenShoot() {
        app.session?.resetTuningToDefault()
        takeBaseline()
    }

    /// Takes the counts now as the "before" of the count lines.
    func takeBaseline() {
        guard let session = app.session else {
            baseline = nil
            return
        }
        baseline = (session.sessionID, counts(in: session))
    }

    private func counts(in session: SessionModel) -> TuningCounts {
        session.hasOwnTuning ? session.counts(for: settings.defaultTuning) : session.tuningCounts
    }

    /// The live count line of a control, or nil when it has none: no shoot open, a control that
    /// counts nothing, or stacks and duplicate sets of a shoot that does not follow the default
    /// (they are not recomputed for another tuning).
    func countLine(_ control: TuningControl) -> String? {
        guard let session = app.session, let counted = control.counted else { return nil }
        if control.isOff(in: settings.defaultTuning) { return localized("\(control.countName): off") }
        let grouping: Bool = switch counted {
        case .stackedPhotos, .exactDuplicatePhotos, .nearDuplicatePhotos: true
        default: false
        }
        if grouping, session.hasOwnTuning { return nil }
        let now = counts(in: session)
        if baseline?.sessionID != session.sessionID { baseline = (session.sessionID, now) }
        let before = baseline?.counts ?? now
        return control.countLine(before: before.count(counted), after: now.count(counted))
    }

    /// True while stacks or duplicate sets are being recomputed after a change.
    func isUpdating(_ control: TuningControl) -> Bool {
        guard let session = app.session, !session.hasOwnTuning else { return false }
        return control.key.affectsGrouping && session.isRegrouping
    }

    // MARK: - Keys

    var keyBindings: KeyBindings { settings.keyBindings }

    /// Starts recording a key for a command: one that replaces `chord` (by default the
    /// command's first key), or with `adding`, one more key. The command's other keys stay.
    func startRecording(_ command: Command, replacing chord: KeyChord? = nil, adding: Bool = false) {
        recording = command
        recordingAdds = adding
        recordingChord = adding ? nil : (chord ?? settings.keyBindings.primaryChord(for: command))
        pendingConflict = nil
        pendingChord = nil
    }

    func cancelRecording() {
        recording = nil
        recordingChord = nil
        recordingAdds = false
        pendingConflict = nil
        pendingChord = nil
    }

    /// A key pressed while recording. Escape cancels, Delete removes the key being replaced; a
    /// free chord is taken at once; a chord in use waits for `confirmConflict()`; a fixed one is
    /// refused.
    func record(_ chord: KeyChord) {
        guard let command = recording else { return }
        if KeyBindings.isRecorderControl(chord) {
            if chord.special == .delete, let old = recordingChord { settings.keyBindings.remove(old, from: command) }
            cancelRecording()
            return
        }
        switch settings.keyBindings.conflict(assigning: chord, to: command) {
        case nil:
            settings.keyBindings.replace(recordingChord, with: chord, for: command)
            cancelRecording()
        case .some(let conflict):
            pendingConflict = conflict
            pendingChord = chord
        }
    }

    /// Takes the chord from the command that had it.
    func confirmConflict() {
        guard let command = recording, let chord = pendingChord, case .command = pendingConflict else { return }
        settings.keyBindings.replace(recordingChord, with: chord, for: command)
        cancelRecording()
    }

    func resetKey(_ command: Command) {
        settings.keyBindings.reset(command)
    }

    func resetAllKeys() {
        cancelRecording()
        settings.keyBindings = .defaults
    }

    func isDefault(_ command: Command) -> Bool {
        settings.keyBindings.chords(for: command) == KeyBindings.defaults.chords(for: command)
    }

    /// The key map's own problems (a chord listed twice, a fixed chord), as warnings.
    var mapConflicts: [String] {
        settings.keyBindings.conflicts.map(\.message)
    }

    // MARK: - Rescanning settings

    /// The current value of a rescanning setting.
    func value(of option: ScanOption) -> Bool {
        switch option {
        case .includeSubfolders: settings.includeSubfolders
        case .pairRAWWithRendered: settings.pairRAWWithRendered
        }
    }

    /// "Include subfolders" and "Treat RAW+JPEG as one photo" scan the open shoot again, and
    /// photos can leave it, with their decisions. With a shoot open, this looks first at what
    /// would leave and, when anything would, asks; otherwise it changes the setting at once.
    func requestScanChange(_ option: ScanOption, to value: Bool) async {
        guard value != self.value(of: option) else { return }
        guard let session = app.session else {
            apply(option, value)
            return
        }
        let leaving = await ShootDiskMonitor.photosLeaving(
            folder: session.folder,
            includeSubfolders: option == .includeSubfolders ? value : settings.includeSubfolders,
            pairRAW: option == .pairRAWWithRendered ? value : settings.pairRAWWithRendered,
            photos: session.state.photos
        )
        guard let leaving, !leaving.isEmpty, app.session === session else {
            apply(option, value)
            return
        }
        let decided = leaving.filter { id in
            guard let photo = session.state.photo(id) else { return false }
            return photo.decision != .unreviewed || photo.rating > 0
        }.count
        pendingScanChange = Self.scanChange(option, value: value, leaving: leaving.count, decided: decided, shoot: session.name, keys: settings.keyBindings)
    }

    static func scanChange(_ option: ScanOption, value: Bool, leaving: Int, decided: Int, shoot: String, keys: KeyBindings = .defaults) -> ScanChange {
        let question = switch option {
        case .includeSubfolders: localized("Stop including subfolders?")
        case .pairRAWWithRendered: value ? localized("Treat RAW+JPEG pairs as one photo?") : localized("Show RAW and JPEG files separately?")
        }
        let what = switch option {
        case .includeSubfolders: localized("\(leaving) photos in subfolders of “\(shoot)” will leave this session.")
        case .pairRAWWithRendered:
            value ? localized("\(leaving) RAW files now shown on their own will be paired with the JPEG or HEIC files of the same name and no longer appear as separate photos.")
                  : localized("\(leaving) photos will be shown as separate RAW and JPEG files.")
        }
        let decisions = decided == 0
            ? localized("None of them has a decision or a rating.")
            : localized("\(decided) photos with a decision or a rating will lose it.") + " " + KeyText.undoSentence(.cannotBringItBack, in: keys)
        let nothingOnDisk = localized("Nothing on disk changes.")
        return ScanChange(
            option: option, value: value, leaving: leaving, leavingDecided: decided, question: question,
            detail: "\(what) \(decisions) \(nothingOnDisk)",
            buttonTitle: option == .includeSubfolders
                ? localized("Leave Out Subfolders") : (value ? localized("Pair Them") : localized("Separate Them"))
        )
    }

    func confirmScanChange() {
        guard let change = pendingScanChange else { return }
        pendingScanChange = nil
        apply(change.option, change.value)
    }

    func cancelScanChange() {
        pendingScanChange = nil
    }

    private func apply(_ option: ScanOption, _ value: Bool) {
        switch option {
        case .includeSubfolders: settings.includeSubfolders = value
        case .pairRAWWithRendered: settings.pairRAWWithRendered = value
        }
    }

    // MARK: - Performance

    struct ConcurrencyInfo: Equatable {
        var count: Int
        var explanation: String
    }

    /// How many photos are analysed at once now, and why, in words.
    var concurrency: ConcurrencyInfo {
        let engineDefault = AnalysisScheduler.defaultConcurrency
        let memory = ProcessInfo.processInfo.physicalMemory
        let power = app.power
        let limit = AnalysisConcurrency.limit(
            engineDefault: engineDefault, physicalMemory: memory, onBattery: power.onBattery,
            reduceOnBattery: settings.reduceAnalysisOnBattery, memoryPressure: power.memoryPressure
        )
        let cap = AnalysisConcurrency.memoryCap(physicalMemory: memory)
        let gigabytes = Int((Double(memory) / 1_073_741_824).rounded())
        var parts = [localized("One per processor core, at most \(engineDefault) on this Mac.")]
        if cap < engineDefault {
            parts.append(localized("Each photo in flight needs about 256 MB, so \(gigabytes) GB of memory allows \(cap)."))
        }
        if power.onBattery {
            parts.append(settings.reduceAnalysisOnBattery ? localized("Halved while on battery.") : localized("On battery, at full speed."))
        }
        switch power.memoryPressure {
        case .normal: break
        case .warning: parts.append(localized("Halved while memory is short."))
        case .critical: parts.append(localized("One at a time while memory is critically short."))
        }
        return ConcurrencyInfo(count: limit, explanation: parts.joined(separator: " "))
    }

    func clearCache(scores: Bool) {
        Task { await app.clearCache(scores: scores) }
    }

    // MARK: - Editor

    /// Asks for the application Open Keepers In uses.
    func chooseEditor() {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [.application]
        panel.directoryURL = URL(fileURLWithPath: "/Applications")
        panel.canChooseDirectories = false
        panel.allowsMultipleSelection = false
        panel.prompt = localized("settings.editor.choose", default: "Choose")
        panel.message = localized("Choose the application Open Keepers In uses.")
        panel.begin { [weak self] response in
            guard response == .OK, let url = panel.url else { return }
            MainActor.assumeIsolated { self?.settings.editorApplication = url }
        }
    }

    // MARK: - Dump

    /// The window's state for the automation dump: the pane, its scope line and every count line.
    var dumpLines: [String: Any] {
        var lines: [String: Any] = [:]
        if let tuningPane = pane.tuningPane {
            for section in tuningPane.sections {
                for control in section.controls where section.showsCount(control) {
                    lines[control.key.rawValue] = countLine(control) ?? NSNull()
                }
            }
        }
        return lines
    }
}
