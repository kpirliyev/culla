import CullaAnalysis
import CullaCore
import CullaFiles
import Foundation

/// The plain-text results: one CSV row per photo, and the summary printed at the end of a run.
enum Report {
    // MARK: - Numbers shared by the summary and the index page

    struct Stats {
        var photos: Int
        var unreadable: Int
        var analysed: Int
        var reused: Int
        var wallSeconds: Double
        var photosPerSecond: Double?
        var meanDecode: Double
        var meanPixels: Double
        var meanVision: Double
        var withMainFace: Int
        /// How many photos each flag catches, in `PhotoFlag.allCases` order.
        var flagCounts: [(flag: PhotoFlag, count: Int)]
        var stacks: Int
        var stackedPhotos: Int
        var exactSets: Int
        var nearSets: Int
    }

    static func stats(_ evaluation: Evaluation) -> Stats {
        let timings = evaluation.records.compactMap { $0.scores?.timings }
        let count = Double(max(timings.count, 1))
        let run = evaluation.run
        return Stats(
            photos: evaluation.records.count,
            unreadable: evaluation.unreadable.count,
            analysed: run.analysed,
            reused: run.reused,
            wallSeconds: run.wallSeconds,
            photosPerSecond: run.analysed > 0 && run.wallSeconds > 0 ? Double(run.analysed) / run.wallSeconds : nil,
            meanDecode: timings.reduce(0) { $0 + $1.decode } / count,
            meanPixels: timings.reduce(0) { $0 + $1.pixels } / count,
            meanVision: timings.reduce(0) { $0 + $1.vision } / count,
            withMainFace: evaluation.summaries.filter { $0?.mainFaces.isEmpty == false }.count,
            flagCounts: PhotoFlag.allCases.map { flag in
                (flag, evaluation.summaries.filter { $0?.flags.contains(flag) == true }.count)
            },
            stacks: evaluation.stacking.stacks.count,
            stackedPhotos: evaluation.stacking.stacks.reduce(0) { $0 + $1.count },
            exactSets: evaluation.duplicates.filter { $0.kind == .exact }.count,
            nearSets: evaluation.duplicates.filter { $0.kind == .near }.count
        )
    }

    static func summary(_ evaluation: Evaluation) -> String {
        let stats = stats(evaluation)
        var lines: [String] = []
        var analysed = "  Analysed:    \(stats.analysed) new, \(stats.reused) reused from the last run"
        if stats.unreadable > 0 { analysed += ", \(stats.unreadable) unreadable" }
        lines.append(analysed)
        if let rate = stats.photosPerSecond {
            lines.append(String(format: "  Speed:       %.1f s for %@, %.1f photos per second with %d at once",
                                stats.wallSeconds, counted(stats.analysed, "photo", "photos"), rate,
                                evaluation.options.jobs))
        }
        lines.append(String(format: "  Per photo:   decode %.2f s, pixel measures %.2f s, Vision %.2f s",
                            stats.meanDecode, stats.meanPixels, stats.meanVision))
        let sources = evaluation.run.sources
        if !sources.isEmpty {
            let parts: [(AnalysisImageSource, String)] = [
                (.embeddedPreview, "from embedded RAW previews"), (.rawDecode, "RAW decodes"), (.decode, "decoded"),
            ]
            lines.append("  Images:      " + parts.compactMap { source, label in
                sources[source].map { "\($0) \(label)" }
            }.joined(separator: ", "))
        }
        let faces = stats.withMainFace == 1 ? "1 photo has" : "\(stats.withMainFace) photos have"
        lines.append("  Faces:       \(faces) a main face")
        lines.append("  Flagged:     " + stats.flagCounts.map { "\($0.flag.label) \($0.count)" }.joined(separator: ", "))
        lines.append("  Stacks:      \(counted(stats.stacks, "stack", "stacks")) holding \(counted(stats.stackedPhotos, "photo", "photos"))")
        lines.append("  Duplicates:  \(counted(stats.exactSets, "exact set", "exact sets")), "
            + counted(stats.nearSets, "near-duplicate set", "near-duplicate sets"))
        lines.append("  Results:     \(evaluation.layout.page("index.html").path)")
        return lines.joined(separator: "\n")
    }

    // MARK: - CSV

    static func writeCSV(_ evaluation: Evaluation) throws {
        let header = [
            "file", "capture_time", "width", "height", "camera", "iso", "shutter_s", "aperture", "focal_mm",
            "faces", "main_faces", "eye_openness", "core_image_blink", "blur_score", "face_sharpness",
            "subject_sharpness", "frame_sharpness", "edge_strength", "clipped_highlights", "clipped_shadows",
            "aesthetics", "utility", "lens_smudge", "horizon_degrees", "face_cut_by_edge", "stack",
            "duplicate_set", "flags", "error",
        ]
        var duplicateSet: [Int: String] = [:]
        for (number, set) in evaluation.duplicates.enumerated() {
            for member in set.members { duplicateSet[member] = "\(set.kind.rawValue)-\(number + 1)" }
        }

        let dateFormat = Date.ISO8601FormatStyle(includingFractionalSeconds: true)
        var rows = [header.joined(separator: ",")]
        for (index, record) in evaluation.records.enumerated() {
            let scores = record.scores
            let summary = evaluation.summaries[index]
            let metadata = record.metadata
            let camera = [metadata.cameraMake, metadata.cameraModel].compactMap { $0 }.joined(separator: " ")
            let fields: [String] = [
                record.id,
                metadata.captureDate.map { $0.formatted(dateFormat) } ?? "",
                metadata.pixelWidth.map(String.init) ?? "",
                metadata.pixelHeight.map(String.init) ?? "",
                camera,
                number(metadata.iso, 0),
                number(metadata.exposureTime, 5),
                number(metadata.fNumber, 1),
                number(metadata.focalLength, 1),
                scores.map { String($0.faces.count) } ?? "",
                summary.map { String($0.mainFaces.count) } ?? "",
                number(summary?.eyeOpenness, 3),
                summary.map { $0.blinkFlagged ? "1" : "0" } ?? "",
                number(summary?.blurScore, 1),
                number(summary?.faceSharpness, 1),
                number(scores?.subjectSharpness, 1),
                number(scores?.frameSharpness, 1),
                number(summary?.edgeStrength, 1),
                number(scores?.clippedHighlights, 4),
                number(scores?.clippedShadows, 4),
                number(scores?.aesthetics, 3),
                scores?.isUtility.map { $0 ? "1" : "0" } ?? "",
                number(scores?.smudgeConfidence, 3),
                number(scores?.horizonDegrees, 2),
                summary.map { $0.hasFaceCutByEdge ? "1" : "0" } ?? "",
                evaluation.stackNumber[index].map(String.init) ?? "",
                duplicateSet[index] ?? "",
                summary.map(flagField) ?? "",
                record.error ?? "",
            ]
            rows.append(fields.map(escape).joined(separator: ","))
        }
        try (rows.joined(separator: "\n") + "\n").write(to: evaluation.layout.scoresCSV, atomically: true, encoding: .utf8)
    }

    private static func number(_ value: Double?, _ digits: Int) -> String {
        value.map { String(format: "%.\(digits)f", $0) } ?? ""
    }

    /// A photo's flags for the CSV: their names joined with "+", in a fixed order, empty when none.
    static func flagField(_ summary: PhotoSummary) -> String {
        PhotoFlag.allCases.filter(summary.flags.contains).map(\.rawValue).joined(separator: "+")
    }

    static func escape(_ field: String) -> String {
        guard field.contains(where: { $0 == "," || $0 == "\"" || $0.isNewline }) else { return field }
        return "\"" + field.replacingOccurrences(of: "\"", with: "\"\"") + "\""
    }
}

/// A count with its noun in the right number: "1 photo", "2 photos", "0 photos".
func counted(_ count: Int, _ singular: String, _ plural: String) -> String {
    "\(count) \(count == 1 ? singular : plural)"
}

extension PhotoFlag {
    /// The flag's name in running text.
    var label: String {
        switch self {
        case .eyesClosed: "eyes closed"
        case .blurry: "blurry"
        case .clippedHighlights: "clipped highlights"
        case .clippedShadows: "clipped shadows"
        case .lowAesthetics: "low aesthetics"
        case .tiltedHorizon: "tilted horizon"
        case .faceCutOff: "face cut off"
        case .lensSmudge: "lens smudge"
        case .utility: "utility"
        }
    }
}
