import CullaAnalysis
import CullaCore
import CullaSession
import SwiftUI

/// Details of the focused photo: its decision and rating, then flags (from analysis, in a later
/// milestone), capture data, exposure, the image and the file.
struct InspectorView: View {
    let model: SessionModel

    var body: some View {
        Group {
            if let photo = model.focusedPhoto {
                ScrollView {
                    VStack(alignment: .leading, spacing: 18) {
                        header(photo)
                        if model.targets.count > 1 {
                            Text(localized("\(model.targets.count) photos selected. Details are for the focused photo."))
                                .font(.callout)
                                .foregroundStyle(.secondary)
                        }
                        FlagsSection(photo: photo, summary: model.session.summary(for: photo.id), tuning: model.session.tuning,
                                     isAnalysing: model.analysis?.isFinished == false)
                        InspectorSection(title: localized("inspector.capture", default: "Capture"), rows: captureRows(photo))
                        InspectorSection(title: localized("inspector.exposure", default: "Exposure"), rows: exposureRows(photo))
                        InspectorSection(title: localized("inspector.image", default: "Image"), rows: imageRows(photo))
                        InspectorSection(title: localized("inspector.file", default: "File"), rows: fileRows(photo))
                    }
                    .padding(16)
                    .frame(maxWidth: .infinity, alignment: .leading)
                }
                .scrollIndicators(.automatic)
            } else {
                Text(localized("No photo selected"))
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }
        .background(Palette.panelBackgroundColor)
        .accessibilityLabel(localized("inspector.accessibilityLabel", default: "Inspector"))
    }

    private func header(_ photo: PhotoItem) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(alignment: .firstTextBaseline, spacing: 6) {
                Text(photo.file.name)
                    .font(.system(size: 14, weight: .semibold))
                    .lineLimit(2)
                    .truncationMode(.middle)
                    .textSelection(.enabled)
                if photo.isNew { NewPill() }
            }
            HStack(spacing: 12) {
                DecisionLabel(decision: photo.decision, isUnreadable: photo.isUnreadable)
                    .font(.callout)
                StarsView(rating: photo.rating, size: 11)
            }
        }
    }

    private var unknown: String { localized("inspector.unknown", default: "Unknown") }

    private func captureRows(_ photo: PhotoItem) -> [InspectorRow] {
        let metadata = photo.metadata
        return [
            InspectorRow(localized("inspector.taken", default: "Taken"), metadata.captureDate.map(Formatting.captureDate) ?? unknown),
            InspectorRow(localized("inspector.camera", default: "Camera"), Formatting.camera(metadata) ?? unknown),
            InspectorRow(localized("inspector.lens", default: "Lens"), metadata.lensModel ?? unknown),
        ]
    }

    private func exposureRows(_ photo: PhotoItem) -> [InspectorRow] {
        let metadata = photo.metadata
        return [
            InspectorRow(localized("inspector.shutter", default: "Shutter"), metadata.exposureTime.map(Formatting.shutter) ?? "—"),
            InspectorRow(localized("inspector.aperture", default: "Aperture"), metadata.fNumber.map(Formatting.aperture) ?? "—"),
            InspectorRow(localized("inspector.iso", default: "ISO"), metadata.iso.map { String(Int($0.rounded())) } ?? "—"),
            InspectorRow(localized("inspector.focalLength", default: "Focal length"), metadata.focalLength.map(Formatting.focalLength) ?? "—"),
        ]
    }

    private func imageRows(_ photo: PhotoItem) -> [InspectorRow] {
        [
            InspectorRow(localized("inspector.size", default: "Size"), Formatting.dimensions(photo.metadata) ?? unknown),
            InspectorRow(localized("inspector.resolution", default: "Resolution"), Formatting.megapixels(photo.metadata) ?? "—"),
            InspectorRow(localized("inspector.format", default: "Format"), Formatting.format(photo.file)),
        ]
    }

    private func fileRows(_ photo: PhotoItem) -> [InspectorRow] {
        var rows = [
            InspectorRow(localized("inspector.name", default: "Name"), photo.file.name),
            InspectorRow(localized("inspector.folder", default: "Folder"), Formatting.folder(of: photo, shootName: model.name)),
            InspectorRow(localized("inspector.fileSize", default: "File size"), Formatting.bytes(photo.file.fileSize)),
            InspectorRow(localized("inspector.modified", default: "Modified"), Formatting.captureDate(photo.file.modificationDate)),
        ]
        if !photo.file.companions.isEmpty {
            rows.insert(InspectorRow(localized("inspector.pairedWith", default: "Paired with"), photo.file.companions.map(\.lastPathComponent).joined(separator: ", ")), at: 1)
        }
        if let reason = photo.unreadableReason {
            rows.append(InspectorRow(localized("inspector.problem", default: "Problem"), reason))
        }
        return rows
    }
}

struct InspectorRow: Identifiable {
    let label: String
    let value: String
    var id: String { label }

    init(_ label: String, _ value: String) {
        self.label = label
        self.value = value
    }
}

struct InspectorSection: View {
    let title: String
    let rows: [InspectorRow]

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(title)
                .font(.system(size: 11, weight: .semibold))
                .foregroundStyle(.secondary)
                .accessibilityAddTraits(.isHeader)
            Grid(alignment: .leadingFirstTextBaseline, horizontalSpacing: 10, verticalSpacing: 4) {
                ForEach(rows) { row in
                    GridRow {
                        Text(row.label)
                            .foregroundStyle(.secondary)
                            .gridColumnAlignment(.trailing)
                            .frame(minWidth: 64, alignment: .trailing)
                        Text(row.value)
                            .textSelection(.enabled)
                            .lineLimit(3)
                            .truncationMode(.middle)
                            .frame(maxWidth: .infinity, alignment: .leading)
                    }
                    .font(.system(size: 12))
                    .accessibilityElement(children: .combine)
                }
            }
        }
    }
}

/// Culla's flags with their tiers, and the measurements behind them in plain words. The values
/// show even when nothing is flagged, so a person can see how close a photo came.
struct FlagsSection: View {
    let photo: PhotoItem
    let summary: PhotoSummary?
    let tuning: Tuning
    var isAnalysing = false

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(localized("inspector.flags", default: "Flags"))
                .font(.system(size: 11, weight: .semibold))
                .foregroundStyle(.secondary)
                .accessibilityAddTraits(.isHeader)
            if photo.isUnreadable {
                Label(localized("Not analysed: the file can’t be read."), systemImage: "exclamationmark.triangle.fill")
                    .font(.system(size: 12))
                    .foregroundStyle(Palette.flaggedColor)
                if let reason = photo.unreadableReason {
                    Text(reason).font(.system(size: 12)).foregroundStyle(.secondary)
                }
            } else if let summary, let scores = photo.scores {
                let flags = PhotoFlag.allCases.filter { summary.flags.contains($0) }
                if flags.isEmpty {
                    Label(localized("Nothing flagged"), systemImage: "checkmark.seal")
                        .font(.system(size: 12))
                        .foregroundStyle(.secondary)
                } else {
                    ForEach(flags, id: \.self) { flag in
                        let certain = summary.tier(of: flag) == .certain
                        HStack(spacing: 7) {
                            Image(systemName: certain ? "exclamationmark.circle.fill" : "exclamationmark.circle")
                                .foregroundStyle(Palette.flaggedColor)
                            Text(Formatting.flag(flag)).font(.system(size: 12, weight: .medium))
                            Spacer(minLength: 6)
                            Text(certain ? localized("tier.certain", default: "Certain") : localized("tier.likely", default: "Likely"))
                                .font(.system(size: 11, weight: certain ? .semibold : .regular))
                                .foregroundStyle(certain ? AnyShapeStyle(Palette.flaggedColor) : AnyShapeStyle(.secondary))
                        }
                        .accessibilityElement(children: .combine)
                    }
                }
                MeasurementsGrid(rows: Self.measurements(scores: scores, summary: summary, tuning: tuning))
                    .padding(.top, 4)
            } else {
                Text(isAnalysing ? localized("Not analysed yet: Culla is still working through the shoot.") : localized("inspector.notAnalysedYet", default: "Not analysed yet"))
                    .font(.system(size: 12))
                    .foregroundStyle(.secondary)
            }
        }
    }

    /// The measurements behind the flags, in plain words, each with the line it is judged
    /// against as a quieter note.
    static func measurements(scores: PhotoScores, summary: PhotoSummary, tuning: Tuning) -> [Measurement] {
        var rows: [Measurement] = []
        let checked = summary.mainFaces.count
        let found = scores.faces.count
        let eyes = localized("measurement.eyes", default: "Eyes")
        if let openness = summary.eyeOpenness {
            let value = Localization.decimal(openness, fractionDigits: 2)
            let threshold = Localization.decimal(tuning.eyesClosedBelow, fractionDigits: 2)
            rows.append(Measurement(eyes, localized("\(value) open"),
                                    note: localized("Lowest reading of \(checked) faces checked; eyes count as closed below \(threshold)")))
        } else if found == 0 {
            rows.append(Measurement(eyes, localized("No faces found")))
        } else {
            rows.append(Measurement(eyes, localized("measurement.notMeasured", default: "Not measured"),
                                    note: localized("\(checked) of \(found) faces checked")))
        }
        let onFace = summary.faceSharpness != nil && tuning.facesTakePriority
        let sharpness = Int(summary.blurScore.rounded())
        rows.append(Measurement(localized("measurement.sharpness", default: "Sharpness"),
                                onFace ? localized("\(sharpness) on a face") : localized("\(sharpness) on the subject"),
                                note: localized("Blurry below \(Int(tuning.blurryBelow.rounded()))")))
        rows.append(Measurement(localized("measurement.highlights", default: "Highlights"),
                                localized("inspector.highlightsClipped", default: "\(Formatting.percent(scores.clippedHighlights)) clipped"),
                                note: localized("Flagged above \(Formatting.percent(tuning.clippedHighlightsAbove))")))
        rows.append(Measurement(localized("measurement.shadows", default: "Shadows"),
                                localized("inspector.shadowsClipped", default: "\(Formatting.percent(scores.clippedShadows)) clipped"),
                                note: localized("Flagged above \(Formatting.percent(tuning.clippedShadowsAbove))")))
        let weakBelow = Localization.decimal(tuning.lowAestheticsBelow, fractionDigits: 2)
        rows.append(Measurement(localized("measurement.aesthetics", default: "Aesthetics"),
                                scores.aesthetics.map { Localization.decimal($0, fractionDigits: 2) } ?? "—",
                                note: scores.aesthetics == nil ? nil : localized("Weak below \(weakBelow)")))
        rows.append(Measurement(localized("measurement.lensSmudge", default: "Lens smudge"),
                                scores.smudgeConfidence.map { localized("\(Formatting.percent($0)) likely") } ?? "—",
                                note: scores.smudgeConfidence == nil ? nil : localized("Flagged above \(Formatting.percent(tuning.lensSmudgeAbove))")))
        let horizonLabel = localized("measurement.horizon", default: "Horizon")
        if let horizon = scores.horizonDegrees {
            let tilt = Localization.decimal(abs(Foundation.remainder(horizon, 180)), fractionDigits: 1)
            let limit = Localization.decimal(tuning.tiltedHorizonAboveDegrees, fractionDigits: 1)
            rows.append(Measurement(horizonLabel, localized("Tilted \(tilt)°"),
                                    note: tuning.flagTiltedHorizon ? localized("Flagged above \(limit)°") : localized("Tilt flag is off")))
        } else {
            rows.append(Measurement(horizonLabel, localized("measurement.noneFound", default: "None found")))
        }
        return rows
    }
}

/// One measurement in the inspector: its value, and the line it is judged against.
struct Measurement: Identifiable {
    let label: String
    let value: String
    let note: String?
    var id: String { label }

    init(_ label: String, _ value: String, note: String? = nil) {
        self.label = label
        self.value = value
        self.note = note
    }
}

/// Measurements in the inspector's label and value style, each note under its value.
private struct MeasurementsGrid: View {
    let rows: [Measurement]

    var body: some View {
        Grid(alignment: .leadingFirstTextBaseline, horizontalSpacing: 10, verticalSpacing: 5) {
            ForEach(rows) { row in
                GridRow {
                    Text(row.label)
                        .foregroundStyle(.secondary)
                        .gridColumnAlignment(.trailing)
                        .frame(minWidth: 64, alignment: .trailing)
                    VStack(alignment: .leading, spacing: 1) {
                        Text(row.value)
                        if let note = row.note {
                            Text(note)
                                .font(.system(size: 10.5))
                                .foregroundStyle(.tertiary)
                                .fixedSize(horizontal: false, vertical: true)
                        }
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                }
                .font(.system(size: 12))
                .accessibilityElement(children: .combine)
            }
        }
    }
}
