import AppKit
import CullaAnalysis
import CullaCommands
import CullaCore
import SwiftUI

/// One pane of the Settings window.
struct SettingsPaneView: View {
    let pane: SettingsPane
    let model: SettingsModel

    var body: some View {
        Group {
            switch pane {
            case .general: GeneralPane(model: model)
            case .performance: PerformancePane(model: model)
            case .keys: KeysPane(model: model)
            default: DetectionPane(pane: pane.tuningPane!, model: model)
            }
        }
        .formStyle(.grouped)
        .frame(width: SettingsWindowController.width)
        // Panes taller than the screen allows scroll at a capped height (see `fitWindow`).
        .fixedSize(horizontal: false, vertical: pane != .keys && !model.scrollingPanes.contains(pane))
        .frame(height: model.scrollingPanes.contains(pane) ? model.scrollingHeight : nil)
        .alert(
            model.pendingScanChange?.question ?? "",
            isPresented: Binding(
                get: { model.pendingScanChange.map { Self.pane(for: $0.option) == pane } ?? false },
                set: { if !$0 { model.cancelScanChange() } }
            ),
            presenting: model.pendingScanChange
        ) { change in
            Button(change.buttonTitle, role: change.leavingDecided > 0 ? .destructive : nil) { model.confirmScanChange() }
            Button(localized("Cancel"), role: .cancel) { model.cancelScanChange() }
        } message: { change in
            Text(verbatim: change.detail)
        }
    }

    /// The pane that shows a rescanning setting, and so its confirmation.
    static func pane(for option: SettingsModel.ScanOption) -> SettingsPane {
        switch option {
        case .includeSubfolders: .general
        case .pairRAWWithRendered: .duplicates
        }
    }
}

// MARK: - Shared rows

/// A row's label: its title, an optional "Provisional" mark, and one line saying what it does.
struct SettingLabel: View {
    let title: String
    var help: String?
    var provisional = false

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            HStack(spacing: 6) {
                Text(verbatim: title)
                if provisional { ProvisionalMark() }
            }
            if let help {
                Text(verbatim: help)
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }
}

/// Marks a value chosen without looking at real shoots, to be tuned in M7.
struct ProvisionalMark: View {
    var body: some View {
        Text(localized("settings.provisional", default: "Provisional"))
            .font(.system(size: 10, weight: .medium))
            .foregroundStyle(.secondary)
            .padding(.horizontal, 5)
            .padding(.vertical, 1)
            .overlay(Capsule().strokeBorder(Color.secondary.opacity(0.5), lineWidth: 0.5))
            .help(localized("Chosen without looking at real shoots yet; to be tuned before release."))
            .accessibilityLabel(localized("Provisional value"))
    }
}

/// The small live count under a control: "Eyes closed: 12 → 9 photos".
struct CountLine: View {
    let text: String?
    var isUpdating = false

    var body: some View {
        if let text {
            HStack(spacing: 4) {
                if isUpdating { ProgressView().controlSize(.mini) }
                Text(verbatim: text)
                    .font(.caption)
                    .monospacedDigit()
                    .foregroundStyle(.secondary)
            }
            .accessibilityElement(children: .combine)
        }
    }
}

// MARK: - Detection panes

/// Eyes, Blur, Similarity, Duplicates, Exposure and Other: the preset, then the pane's controls
/// built from the same `TuningControl` descriptions as the tuning panel, each with its live count.
struct DetectionPane: View {
    let pane: TuningPane
    let model: SettingsModel

    var body: some View {
        // Read here so the pane redraws as the default changes.
        let tuning = model.defaultTuning
        Form {
            Section {
                PresetPicker(model: model)
                ScopeLine(model: model)
            }
            ForEach(Array(pane.sections.enumerated()), id: \.offset) { index, section in
                Section {
                    ForEach(section.controls) { control in
                        DetectionRow(control: control, model: model, tuning: tuning, showsCount: section.showsCount(control))
                    }
                    if pane == .duplicates, section.title == nil { pairRow }
                } header: {
                    if let title = section.title {
                        PaneSectionHeader(title: title, note: section.note,
                                          provisional: section.controls.allSatisfy(\.isProvisional))
                    }
                } footer: {
                    if index == pane.sections.count - 1 {
                        HStack {
                            Spacer()
                            Button(localized("Reset \(pane.title) to Defaults")) { model.resetPane(pane) }
                                .disabled(model.paneIsAtBalanced(pane))
                        }
                        .padding(.top, 4)
                    }
                }
            }
        }
    }

    /// Duplicates: RAW+JPEG pairing is a property of the scan, not of `Tuning`.
    private var pairRow: some View {
        LabeledContent {
            Toggle(localized("Treat RAW+JPEG as one photo"), isOn: Binding(
                get: { model.settings.pairRAWWithRendered },
                set: { value in Task { await model.requestScanChange(.pairRAWWithRendered, to: value) } }
            ))
                .labelsHidden()
                .toggleStyle(.switch)
        } label: {
            SettingLabel(title: localized("Treat RAW+JPEG as one photo"),
                         help: localized("A RAW file and the JPEG or HEIC of the same name are decided together. The open shoot is scanned again."))
        }
    }
}

struct PaneSectionHeader: View {
    let title: String
    var note: String?
    var provisional = false

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            HStack(spacing: 6) {
                Text(verbatim: title)
                if provisional { ProvisionalMark() }
            }
            if let note {
                Text(verbatim: note).font(.callout).foregroundStyle(.secondary).fontWeight(.regular)
            }
        }
    }
}

/// Lenient, Balanced, Strict: sets every detection slider at once. Shows Custom when a slider
/// was moved by hand.
struct PresetPicker: View {
    let model: SettingsModel

    var body: some View {
        let preset = model.preset
        LabeledContent {
            Picker(localized("settings.preset", default: "Preset"), selection: Binding<TuningPreset?>(
                get: { preset },
                set: { if let value = $0 { model.applyPreset(value) } }
            )) {
                ForEach(TuningPreset.allCases, id: \.self) { preset in
                    Text(verbatim: preset.title).tag(Optional(preset))
                }
            }
            .pickerStyle(.segmented)
            .labelsHidden()
            // As wide as its segments need in every language, and never narrower than before.
            .fixedSize()
            .frame(minWidth: 270)
        } label: {
            VStack(alignment: .leading, spacing: 2) {
                HStack(spacing: 6) {
                    Text(localized("settings.preset", default: "Preset"))
                    if preset == nil {
                        Text(localized("settings.preset.custom", default: "Custom"))
                            .font(.system(size: 11, weight: .semibold))
                            .foregroundStyle(.secondary)
                    }
                    if preset == .lenient || preset == .strict { ProvisionalMark() }
                }
                Text(preset?.summary ?? localized("Changed by hand. A preset sets every slider again."))
                    .font(.callout)
                    .foregroundStyle(.secondary)
            }
        }
    }
}

/// Where the pane's counts come from, and the way back to the default for a shoot adjusted
/// from its own tuning panel.
struct ScopeLine: View {
    let model: SettingsModel

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 8) {
            Image(systemName: model.scope == .noShoot ? "photo.on.rectangle" : "info.circle")
                .foregroundStyle(.secondary)
            Text(verbatim: model.scopeNote)
                .font(.callout)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            Spacer(minLength: 0)
            if case .ownTuning = model.scope {
                Button(localized("Use Defaults for This Shoot")) { model.useDefaultForOpenShoot() }
                    .controlSize(.small)
            }
        }
    }
}

/// One detection control: a slider (as a 0 to 100 sensitivity where the Design doc asks for one),
/// a switch or a choice, with its live count.
struct DetectionRow: View {
    let control: TuningControl
    let model: SettingsModel
    let tuning: Tuning
    var showsCount = true

    var body: some View {
        let value = control.key.value(in: tuning)
        let disabled = control.dependsOn.map { $0.value(in: tuning) < 0.5 } ?? false
        LabeledContent {
            VStack(alignment: .trailing, spacing: 3) {
                editor(value: value)
                if showsCount {
                    CountLine(text: model.countLine(control), isUpdating: model.isUpdating(control))
                }
            }
        } label: {
            SettingLabel(title: control.title, help: control.help, provisional: control.isProvisional)
        }
        .disabled(disabled)
        .help(control.help)
    }

    @ViewBuilder
    private func editor(value: Double) -> some View {
        if control.isSwitch {
            Toggle(control.title, isOn: Binding(get: { value >= 0.5 }, set: { model.setValue(control.key, $0 ? 1 : 0) }))
                .labelsHidden()
                .toggleStyle(.switch)
        } else if control.isChoice {
            Picker(control.title, selection: Binding(get: { Int(value.rounded()) }, set: { model.setValue(control.key, Double($0)) })) {
                ForEach(Array(control.choices.enumerated()), id: \.offset) { index, name in
                    Text(verbatim: name).tag(index)
                }
            }
            .labelsHidden()
            .fixedSize()
        } else {
            VStack(alignment: .trailing, spacing: 1) {
                HStack(spacing: 10) {
                    Slider(value: sliderBinding(value), in: sliderRange)
                        .controlSize(.small)
                        .frame(width: 170)
                        .accessibilityLabel(Text(verbatim: control.title))
                        .accessibilityValue(Text(verbatim: control.valueNote(value) ?? control.format(value)))
                    Text(verbatim: control.shownValue(value))
                        .monospacedDigit()
                        .frame(width: 44, alignment: .trailing)
                }
                if let note = control.valueNote(value) {
                    Text(verbatim: note).font(.caption).monospacedDigit().foregroundStyle(.secondary)
                }
            }
        }
    }

    private var sliderRange: ClosedRange<Double> {
        control.isSensitivity ? 0...100 : control.range
    }

    private func sliderBinding(_ value: Double) -> Binding<Double> {
        if control.isSensitivity {
            return Binding(
                get: { control.sensitivity(of: value) },
                set: { model.setValue(control.key, control.value(atSensitivity: $0)) }
            )
        }
        return Binding(get: { value }, set: { model.setValue(control.key, $0) })
    }
}

// MARK: - General

struct GeneralPane: View {
    let model: SettingsModel

    var body: some View {
        let settings = model.settings
        Form {
            LanguageSection(settings: settings, app: model.app)
            Section(localized("settings.section.culling", default: "Culling")) {
                toggle(localized("Advance after a decision"), KeyText.advanceNote(settings.keyBindings),
                       Binding(get: { settings.advanceAfterDecision }, set: { settings.advanceAfterDecision = $0 }))
                toggle(localized("Collapse stacks in All Photos"), KeyText.collapseStacksNote(settings.keyBindings),
                       Binding(get: { settings.collapseStacksInAllPhotos }, set: { settings.collapseStacksInAllPhotos = $0 }))
                toggle(localized("Show best pick beside the current frame"), KeyText.bestPickPaneNote(settings.keyBindings),
                       Binding(get: { settings.showsBestPickPane }, set: { settings.showsBestPickPane = $0 }))
                toggle(localized("Include subfolders"), localized("Folders inside the shoot folder are part of the shoot."),
                       Binding(get: { settings.includeSubfolders },
                               set: { value in Task { await model.requestScanChange(.includeSubfolders, to: value) } }))
            }
            Section(localized("settings.section.applying", default: "Applying decisions")) {
                LabeledContent {
                    Picker(localized("Reject action"), selection: Binding(get: { settings.rejectAction }, set: { settings.rejectAction = $0 })) {
                        Text(localized("Move to a _Rejected folder")).tag(RejectAction.moveToRejectedFolder)
                        Text(localized("Mark only, in sidecars")).tag(RejectAction.markOnly)
                        Text(localized("Move to the Trash")).tag(RejectAction.moveToTrash)
                    }
                    .labelsHidden()
                    .fixedSize()
                } label: {
                    SettingLabel(title: localized("Reject action"), help: localized("Review and Apply can change it for one apply."))
                }
                LabeledContent {
                    HStack(spacing: 8) {
                        if let editor = settings.editorApplication {
                            Image(nsImage: NSWorkspace.shared.icon(forFile: editor.path))
                                .resizable()
                                .frame(width: 18, height: 18)
                            Text(verbatim: editor.deletingPathExtension().lastPathComponent)
                        } else {
                            Text(localized("None chosen")).foregroundStyle(.secondary)
                        }
                        Button(settings.editorApplication == nil
                               ? localized("settings.editor.chooseEllipsis", default: "Choose…")
                               : localized("settings.editor.change", default: "Change…")) { model.chooseEditor() }
                        if settings.editorApplication != nil {
                            Button(localized("settings.editor.forget", default: "Forget")) { settings.editorApplication = nil }
                        }
                    }
                } label: {
                    SettingLabel(title: localized("Open keepers in"), help: localized("After Apply, the result banner offers to open the keepers in this app."))
                }
            }
            SidecarSection(model: model)
        }
    }

    private func toggle(_ title: String, _ help: String, _ isOn: Binding<Bool>) -> some View {
        LabeledContent {
            Toggle(title, isOn: isOn)
                .labelsHidden()
                .toggleStyle(.switch)
        } label: {
            SettingLabel(title: title, help: help)
        }
    }
}

/// Settings ▸ General ▸ Language: System default, or one of Culla's languages, each named in its
/// own language. The choice takes effect when Culla is next opened (`AppSettings.language`), so
/// once it differs from the one Culla started with, a button quits and reopens Culla.
struct LanguageSection: View {
    let settings: AppSettings
    let app: AppModel

    var body: some View {
        Section(localized("settings.section.language", default: "Language")) {
            LabeledContent {
                Picker(localized("settings.language", default: "Language"),
                       selection: Binding(get: { settings.language }, set: { settings.language = $0 })) {
                    Text(localized("settings.language.system", default: "System default")).tag(AppLanguage?.none)
                    Divider()
                    ForEach(AppLanguage.allCases, id: \.self) { language in
                        Text(verbatim: AppSettings.nativeName(language)).tag(Optional(language))
                    }
                }
                .labelsHidden()
                .fixedSize()
            } label: {
                SettingLabel(title: localized("settings.language", default: "Language"),
                             help: localized("Takes effect the next time Culla opens. System default uses the first of Culla’s languages in your list in System Settings, or English if none is there."))
            }
            if settings.language != settings.launchChoice {
                HStack {
                    Spacer()
                    Button(localized("Quit and Reopen Culla")) { app.quitAndReopen() }
                        .accessibilityHint(localized("Saves every decision, quits Culla and opens it again in the chosen language."))
                }
            }
        }
    }
}

/// What a decision and a rating are written as in a sidecar.
struct SidecarSection: View {
    let model: SettingsModel

    /// The XMP label values, written to sidecars in English as Bridge and Lightroom expect.
    static let labels = ["Red", "Yellow", "Green", "Blue", "Purple"]

    /// A label's name on screen. The value written stays the English one above.
    static func labelName(_ label: String) -> String {
        switch label {
        case "Red": localized("label.red", default: "Red")
        case "Yellow": localized("label.yellow", default: "Yellow")
        case "Green": localized("label.green", default: "Green")
        case "Blue": localized("label.blue", default: "Blue")
        case "Purple": localized("label.purple", default: "Purple")
        default: label
        }
    }

    var body: some View {
        let settings = model.settings
        let mapping = settings.sidecarMapping
        Section {
            LabeledContent {
                Toggle(localized("Write XMP sidecars"), isOn: Binding(get: { settings.writeSidecars }, set: { settings.writeSidecars = $0 }))
                    .labelsHidden()
                    .toggleStyle(.switch)
            } label: {
                SettingLabel(title: localized("Write XMP sidecars"), help: localized("<name>.xmp beside each photo. Image files are never changed."))
            }
            Group {
                sidecarRows(mapping: mapping, settings: settings)
            }
            .disabled(!settings.writeSidecars)
        } header: {
            Text(localized("settings.section.sidecars", default: "Sidecars"))
        } footer: {
            Text(localized("A photo without a decision or a rating gets no sidecar. An existing sidecar is merged; everything else in it is kept."))
                .font(.callout)
                .foregroundStyle(.secondary)
                .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    @ViewBuilder
    private func sidecarRows(mapping: SidecarMapping, settings: AppSettings) -> some View {
            LabeledContent {
                Toggle(localized("Star ratings"), isOn: Binding(get: { mapping.writesRating }, set: { settings.sidecarMapping.writesRating = $0 }))
                    .labelsHidden()
                    .toggleStyle(.switch)
            } label: {
                SettingLabel(title: localized("Star ratings"), help: localized("Written as the XMP rating, 0 to 5."))
            }
            LabeledContent {
                Picker(localized("Rejected rating"), selection: Binding(
                    get: { mapping.rejectedRating ?? Int.min },
                    set: { settings.sidecarMapping.rejectedRating = $0 == Int.min ? nil : $0 }
                )) {
                    Text(verbatim: "−1").tag(-1)
                    Text(verbatim: "0").tag(0)
                    Divider()
                    Text(localized("Leave alone")).tag(Int.min)
                }
                .labelsHidden()
                .fixedSize()
            } label: {
                SettingLabel(title: localized("Rating for rejects"), help: localized("−1 is what Lightroom and Bridge read as rejected."))
            }
            .disabled(!mapping.writesRating)
            labelRow(localized("Label for kept photos"), value: mapping.keptLabel) { settings.sidecarMapping.keptLabel = $0 }
            labelRow(localized("Label for rejected photos"), value: mapping.rejectedLabel) { settings.sidecarMapping.rejectedLabel = $0 }
    }

    private func labelRow(_ title: String, value: String?, set: @escaping (String?) -> Void) -> some View {
        LabeledContent {
            Picker(title, selection: Binding(get: { value ?? "" }, set: { set($0.isEmpty ? nil : $0) })) {
                ForEach(Self.labels, id: \.self) { label in
                    Text(verbatim: Self.labelName(label)).tag(label)
                }
                Divider()
                Text(localized("settings.label.none", default: "None")).tag("")
            }
            .labelsHidden()
            .fixedSize()
        } label: {
            SettingLabel(title: title, help: nil)
        }
    }
}

// MARK: - Performance

struct PerformancePane: View {
    let model: SettingsModel
    @State private var confirmingClear = false

    var body: some View {
        let settings = model.settings
        let info = model.concurrency
        Form {
            Section(localized("settings.section.analysis", default: "Analysis")) {
                LabeledContent {
                    Picker(localized("Analysis speed"), selection: Binding(get: { settings.reduceAnalysisOnBattery }, set: { settings.reduceAnalysisOnBattery = $0 })) {
                        Text(localized("settings.speed.full", default: "Full")).tag(false)
                        Text(localized("Reduced on battery")).tag(true)
                    }
                    .pickerStyle(.segmented)
                    .labelsHidden()
                    .fixedSize()
                } label: {
                    SettingLabel(title: localized("Analysis speed"), help: localized("Reduced: on battery, half as many photos are analysed at once."))
                }
                LabeledContent {
                    Text(verbatim: Formatting.count(info.count))
                        .font(.title3.weight(.semibold))
                        .monospacedDigit()
                } label: {
                    SettingLabel(title: localized("Photos analysed at once"), help: info.explanation)
                }
            }
            Section(localized("settings.section.cache", default: "Cache")) {
                LabeledContent {
                    HStack(spacing: 10) {
                        Slider(value: Binding(get: { settings.cacheLimitGB }, set: { settings.cacheLimitGB = $0.rounded() }),
                               in: AppSettings.cacheLimitRange)
                            .controlSize(.small)
                            .frame(width: 170)
                            .accessibilityLabel(localized("Cache size limit"))
                        Text(verbatim: Self.gigabytes(Int(settings.cacheLimitGB)))
                            .monospacedDigit()
                            .frame(width: 44, alignment: .trailing)
                    }
                } label: {
                    SettingLabel(title: localized("Cache size limit"), help: localized("Thumbnails beyond this are removed, least recently used first."))
                }
                LabeledContent {
                    VStack(alignment: .trailing, spacing: 4) {
                        if let usage = model.app.cacheUsage {
                            Text(verbatim: Self.usage(Self.bytes(usage.thumbnailBytes), of: Int(settings.cacheLimitGB)))
                                .monospacedDigit()
                            ProgressView(value: min(1, Double(usage.thumbnailBytes) / Double(settings.cacheLimitBytes)))
                                .frame(width: 170)
                                .controlSize(.small)
                        } else {
                            ProgressView().controlSize(.small)
                        }
                    }
                } label: {
                    SettingLabel(title: localized("settings.cache.thumbnails", default: "Thumbnails"), help: localized("Made again as photos are shown."))
                }
                LabeledContent {
                    Text(verbatim: model.app.cacheUsage.map { Formatting.photos($0.cachedScores) } ?? "—")
                        .monospacedDigit()
                } label: {
                    SettingLabel(title: localized("Analysis scores"), help: localized("Kept so a shoot opened again is not analysed again."))
                }
                HStack {
                    Spacer()
                    Button(localized("Clear Cache…")) { confirmingClear = true }
                }
            }
        }
        .alert(localized("Clear the cache?"), isPresented: $confirmingClear) {
            Button(localized("Clear Thumbnails")) { model.clearCache(scores: false) }
            Button(localized("Clear Thumbnails and Scores"), role: .destructive) { model.clearCache(scores: true) }
            Button(localized("Cancel"), role: .cancel) {}
        } message: {
            Text(localized("Thumbnails are made again as photos are shown. Without cached scores, each shoot is analysed again the next time it opens. Decisions are never touched."))
        }
        .task { await model.app.measureCache() }
    }

    static func bytes(_ value: Int64) -> String {
        value.formatted(.byteCount(style: .file, spellsOutZero: false).locale(Localization.locale))
    }

    /// The cache limit beside its slider: "5 GB".
    static func gigabytes(_ value: Int) -> String {
        localized("settings.cache.gigabytes", default: "\(value) GB")
    }

    /// "1.2 GB of 5 GB".
    static func usage(_ used: String, of limit: Int) -> String {
        localized("\(used) of \(limit) GB")
    }
}

// MARK: - Keys

struct KeysPane: View {
    let model: SettingsModel
    @State private var filter = ""

    var body: some View {
        let bindings = model.keyBindings
        VStack(spacing: 0) {
            HStack(spacing: 6) {
                Image(systemName: "magnifyingglass").foregroundStyle(.secondary).accessibilityHidden(true)
                TextField(localized("Find a command or a key"), text: $filter)
                    .textFieldStyle(.plain)
                    .accessibilityLabel(localized("Find a command or a key"))
                if !filter.isEmpty {
                    Button { filter = "" } label: { Image(systemName: "xmark.circle.fill") }
                        .buttonStyle(.borderless)
                        .foregroundStyle(.secondary)
                        .accessibilityLabel(localized("settings.keys.clearSearch", default: "Clear"))
                }
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 6)
            .background(RoundedRectangle(cornerRadius: 7).fill(Color.white.opacity(0.07)))
            .padding(.horizontal, 20)
            .padding(.top, 16)
            Form {
                if !model.mapConflicts.isEmpty {
                    Section {
                        ForEach(model.mapConflicts, id: \.self) { message in
                            Label(message, systemImage: "exclamationmark.triangle")
                        }
                    }
                }
                ForEach(Command.settingsSections, id: \.self) { section in
                    let commands = Command.allCases.filter { $0.settingsSection == section && matches($0, bindings) }
                    if !commands.isEmpty {
                        Section(section) {
                            ForEach(commands, id: \.self) { command in
                                KeyRow(command: command, chords: bindings.chords(for: command), model: model)
                            }
                        }
                    }
                }
            }
            Divider()
            HStack(alignment: .firstTextBaseline, spacing: 12) {
                Image(systemName: "lock")
                    .foregroundStyle(.secondary)
                Text(localized("Click a key to change only that key, or + to add one. Esc cancels, Delete removes it. ⌘Q, ⌘H, ⌘M and the other application and window menu keys are fixed."))
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                Spacer(minLength: 8)
                Button(localized("settings.keys.resetAll", default: "Reset All")) { model.resetAllKeys() }
                    .disabled(bindings == .defaults)
            }
            .padding(.horizontal, 20)
            .padding(.vertical, 12)
        }
        .frame(height: 600)
    }

    /// A command matches the filter by its name or by a key it has ("⇧X", "shift+x").
    private func matches(_ command: Command, _ bindings: KeyBindings) -> Bool {
        let text = filter.trimmingCharacters(in: .whitespaces)
        guard !text.isEmpty else { return true }
        if command.settingsTitle.localizedCaseInsensitiveContains(text) { return true }
        return bindings.chords(for: command).contains {
            $0.displayString.localizedCaseInsensitiveCompare(text) == .orderedSame || $0.description.caseInsensitiveCompare(text) == .orderedSame
        }
    }
}

/// One command and its keys. Each key is a button: clicking it records a key that replaces only
/// that one, so a command's other keys (⌘= beside ⌘+) stay. The plus button adds a key.
struct KeyRow: View {
    let command: Command
    let chords: [KeyChord]
    let model: SettingsModel

    var body: some View {
        let isRecording = model.recording == command
        VStack(alignment: .leading, spacing: 6) {
            LabeledContent {
                HStack(spacing: 6) {
                    if !model.isDefault(command) {
                        Button {
                            model.resetKey(command)
                        } label: {
                            Image(systemName: "arrow.uturn.backward")
                        }
                        .buttonStyle(.borderless)
                        .help(Self.resetHelp(KeyBindings.defaults.chords(for: command).map(\.displayString).joined(separator: ", ")))
                        .accessibilityLabel(localized("Reset \(command.settingsTitle) to its default keys"))
                    }
                    if chords.isEmpty {
                        keyButton(chord: nil, recording: isRecording && !model.recordingAdds)
                    }
                    ForEach(chords, id: \.self) { chord in
                        keyButton(chord: chord, recording: isRecording && !model.recordingAdds && model.recordingChord == chord)
                    }
                    if isRecording && model.recordingAdds {
                        KeyCap(text: localized("Type a key…"), isRecording: true, isEmpty: false)
                    }
                    if !chords.isEmpty {
                        Button {
                            isRecording && model.recordingAdds ? model.cancelRecording() : model.startRecording(command, adding: true)
                        } label: {
                            Image(systemName: "plus")
                        }
                        .buttonStyle(.borderless)
                        .help(localized("Add another key for \(command.settingsTitle)"))
                        .accessibilityLabel(localized("Add a key for \(command.settingsTitle)"))
                    }
                }
            } label: {
                Text(verbatim: command.settingsTitle)
            }
            if isRecording, let conflict = model.pendingConflict {
                HStack(spacing: 8) {
                    Image(systemName: "exclamationmark.triangle.fill")
                        .foregroundStyle(Palette.flaggedColor)
                        .accessibilityHidden(true)
                    Text(verbatim: conflict.message)
                        .font(.callout)
                    Spacer(minLength: 8)
                    if case .command = conflict {
                        Button(localized("Use for \(command.settingsTitle)")) { model.confirmConflict() }
                            .controlSize(.small)
                    }
                    Button(localized("Cancel")) { model.cancelRecording() }
                        .controlSize(.small)
                }
                .padding(8)
                .background(RoundedRectangle(cornerRadius: 6).fill(Palette.flaggedColor.opacity(0.12)))
                .accessibilityElement(children: .contain)
                .accessibilityLabel(localized("settings.keys.warning", default: "Warning"))
            }
        }
    }

    /// One key: a button that records a replacement for it (Escape cancels, Delete removes it).
    private func keyButton(chord: KeyChord?, recording: Bool) -> some View {
        Button {
            recording ? model.cancelRecording() : model.startRecording(command, replacing: chord)
        } label: {
            KeyCap(text: recording ? localized("Type a key…") : chord?.displayString ?? localized("settings.keys.none", default: "None"),
                   isRecording: recording, isEmpty: chord == nil)
        }
        .buttonStyle(.plain)
        .focusable()
        .accessibilityLabel(recording
            ? localized("\(command.settingsTitle): type the new key")
            : chord.map { localized("settings.keys.spokenKey", default: "\(command.settingsTitle): \($0.spokenName)") }
                ?? localized("\(command.settingsTitle): no key"))
        .accessibilityHint(localized("Records a key that replaces this one. Escape cancels, Delete removes it."))
    }

    /// The reset button's tooltip: "Back to ⌘+, ⌘=".
    private static func resetHelp(_ keys: String) -> String {
        localized("settings.keys.resetHelp", default: "Back to \(keys)")
    }
}

struct KeyCap: View {
    let text: String
    let isRecording: Bool
    let isEmpty: Bool

    var body: some View {
        Text(verbatim: text)
            .font(.system(size: 12, weight: .medium))
            .foregroundStyle(isEmpty && !isRecording ? .secondary : .primary)
            .padding(.horizontal, 8)
            .padding(.vertical, 3)
            .frame(minWidth: 86)
            .background(
                RoundedRectangle(cornerRadius: 5)
                    .fill(isRecording ? Palette.accentColor.opacity(0.25) : Color.white.opacity(0.08))
            )
            .overlay(
                RoundedRectangle(cornerRadius: 5)
                    .strokeBorder(isRecording ? Palette.accentColor : Color.white.opacity(0.12), lineWidth: 1)
            )
            .contentShape(Rectangle())
    }
}
