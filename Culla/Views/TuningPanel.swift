import CullaAnalysis
import CullaCommands
import CullaSession
import SwiftUI

/// The tuning panel (Flow 6): a group's main detection controls, each with a live count of what
/// it flags. Moving a control regroups at once from the stored scores; nothing is analysed again
/// and no decision changes. Changes apply to this shoot only, and are kept with it; Save as
/// Default makes them the default for every shoot (Settings shows the default), Reset to Default
/// puts the shoot back on it. The rows are `TuningControlRow`s over the same `TuningControl`
/// descriptions the Settings window uses.
struct TuningPanel: View {
    let model: SessionModel
    let group: GroupID

    var body: some View {
        let session = model.session
        let counts = model.tuningCounts
        let baseline = model.tuningBaseline
        VStack(alignment: .leading, spacing: 14) {
            VStack(alignment: .leading, spacing: 3) {
                Text(localized("Adjust \(group.title)"))
                    .font(.system(size: 13, weight: .semibold))
                Text(localized("Uses the scores Culla already has. Nothing is analysed again, and decisions stay as they are."))
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            groupLine(total: session.count(of: group).total)
            ForEach(TuningControl.controls(for: group)) { control in
                TuningControlRow(
                    control: control,
                    value: Binding(
                        get: { control.key.value(in: session.tuning) },
                        set: { model.setTuningValue(control.key, control.snapped($0)) }
                    ),
                    countLine: countLine(control, counts: counts, baseline: baseline),
                    isUpdating: control.key.affectsGrouping && model.isRegrouping
                )
                .disabled(control.dependsOn.map { $0.value(in: session.tuning) < 0.5 } ?? false)
            }
            Divider()
            VStack(alignment: .leading, spacing: 8) {
                HStack(spacing: 5) {
                    Image(systemName: model.hasOwnTuning ? "slider.horizontal.3" : "checkmark.circle")
                    Text(model.hasOwnTuning ? localized("Changed for this shoot only.") : localized("This shoot uses your default settings."))
                }
                .font(.system(size: 11))
                .foregroundStyle(.secondary)
                // One row when the three buttons fit, else Done on a row of its own; never cut.
                ViewThatFits(in: .horizontal) {
                    HStack(spacing: 8) {
                        resetButton
                        saveButton
                        Spacer(minLength: 8)
                        doneButton
                    }
                    VStack(alignment: .leading, spacing: 8) {
                        HStack(spacing: 8) {
                            resetButton
                            saveButton
                        }
                        HStack {
                            Spacer()
                            doneButton
                        }
                    }
                    VStack(alignment: .leading, spacing: 8) {
                        resetButton
                        saveButton
                        HStack {
                            Spacer()
                            doneButton
                        }
                    }
                }
            }
            .controlSize(.small)
        }
        .padding(16)
        .frame(width: 340)
    }

    private var resetButton: some View {
        Button(localized("tuning.resetToDefault", default: "Reset to Default")) { model.resetTuningToDefault() }
            .disabled(!model.hasOwnTuning)
            .help(localized("Puts every detection setting of this shoot back to your default."))
            .fixedSize()
    }

    private var saveButton: some View {
        Button(localized("tuning.saveAsDefault", default: "Save as Default")) { model.saveTuningAsDefault() }
            .disabled(!model.hasOwnTuning)
            .help(localized("Makes this shoot's settings the default for every shoot."))
            .fixedSize()
    }

    private var doneButton: some View {
        Button(localized("tuning.done", default: "Done")) { model.closeTuningPanel() }
            .keyboardShortcut(.defaultAction)
            .fixedSize()
    }

    /// "Blurry: 12 → 9 photos": the whole group, before and after.
    private func groupLine(total: Int) -> some View {
        let before = model.tuningBaselineTotal
        let title = group.title
        let text = before == total
            ? localized("tuning.groupLine", default: "\(title): \(total) photos")
            : localized("tuning.groupLineChange", default: "\(title): \(before) → \(total) photos")
        return HStack(spacing: 6) {
            Image(systemName: SidebarView.icon(for: group)).foregroundStyle(Palette.flaggedColor)
            Text(verbatim: text).font(.system(size: 12, weight: .semibold)).monospacedDigit()
            if model.isRegrouping, !group.isDefectGroup {
                ProgressView().controlSize(.mini)
            }
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 6)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(RoundedRectangle(cornerRadius: 7).fill(Color.white.opacity(0.06)))
        .accessibilityElement(children: .combine)
    }

    private func countLine(_ control: TuningControl, counts: TuningCounts, baseline: TuningCounts) -> String {
        if control.isOff(in: model.session.tuning) { return localized("\(control.countName): off") }
        guard let counted = control.counted else { return "" }
        return control.countLine(before: baseline.count(counted), after: counts.count(counted))
    }
}

/// One detection control: its label and value, a slider or a switch, and the live count of what
/// it flags ("Eyes closed: 41 → 28 photos"). Built from a `TuningControl`, so the Settings window
/// can show the same rows.
struct TuningControlRow: View {
    let control: TuningControl
    @Binding var value: Double
    let countLine: String
    var isUpdating = false

    var body: some View {
        VStack(alignment: .leading, spacing: 5) {
            if control.isSwitch {
                Toggle(isOn: Binding(get: { value >= 0.5 }, set: { value = $0 ? 1 : 0 })) {
                    Text(verbatim: control.title).font(.system(size: 12, weight: .medium))
                }
                .toggleStyle(.switch)
                .controlSize(.mini)
            } else {
                // The note sits beside the title when both fit, else under it: never cut.
                ViewThatFits(in: .horizontal) {
                    HStack(alignment: .firstTextBaseline) {
                        title
                        if let note = control.valueNote(value) { noteText(note).fixedSize() }
                        Spacer(minLength: 8)
                        valueText
                    }
                    VStack(alignment: .leading, spacing: 2) {
                        HStack(alignment: .firstTextBaseline) {
                            title
                            Spacer(minLength: 8)
                            valueText
                        }
                        if let note = control.valueNote(value) {
                            noteText(note).fixedSize(horizontal: false, vertical: true)
                        }
                    }
                }
                Slider(value: sliderValue, in: control.isSensitivity ? 0...100 : control.range)
                    .controlSize(.small)
                    .accessibilityLabel(Text(verbatim: control.title))
                    .accessibilityValue(Text(verbatim: control.valueNote(value) ?? control.format(value)))
            }
            HStack(spacing: 5) {
                Text(verbatim: countLine)
                    .font(.system(size: 11))
                    .monospacedDigit()
                    .foregroundStyle(.secondary)
                if isUpdating {
                    ProgressView().controlSize(.mini).help(localized("Regrouping"))
                }
            }
            .accessibilityElement(children: .combine)
        }
        .help(control.help)
    }

    private var title: some View {
        Text(verbatim: control.title).font(.system(size: 12, weight: .medium)).fixedSize()
    }

    private var valueText: some View {
        Text(verbatim: control.shownValue(value))
            .font(.system(size: 12, weight: .semibold))
            .monospacedDigit()
            .fixedSize()
    }

    private func noteText(_ note: String) -> some View {
        Text(verbatim: note)
            .font(.system(size: 11))
            .monospacedDigit()
            .foregroundStyle(.secondary)
    }

    /// The slider's position: the value, or its 0 to 100 sensitivity.
    private var sliderValue: Binding<Double> {
        guard control.isSensitivity else { return $value }
        return Binding(
            get: { control.sensitivity(of: value) },
            set: { value = control.value(atSensitivity: $0) }
        )
    }
}
