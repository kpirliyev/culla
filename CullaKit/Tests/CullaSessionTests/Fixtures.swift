import CullaAnalysis
import CullaCore
import CullaSession
import Foundation

/// Builds photos and scores in code, so session tests need no files.
enum Fixtures {
    static let start = Date(timeIntervalSinceReferenceDate: 800_000_000)

    static func file(_ id: String, size: Int64 = 1000, modified: Date = start) -> PhotoFile {
        PhotoFile(
            id: id,
            url: URL(fileURLWithPath: "/shoot/\(id)"),
            fileSize: size,
            modificationDate: modified,
            isRAW: false
        )
    }

    /// A photo taken `seconds` after `start`, or without a capture date when `seconds` is nil.
    static func item(
        _ id: String,
        at seconds: Double?,
        scores: PhotoScores? = nil,
        decision: Decision = .unreviewed,
        modified: Date = start
    ) -> PhotoItem {
        PhotoItem(
            file: file(id, modified: modified),
            metadata: PhotoMetadata(captureDate: seconds.map { start.addingTimeInterval($0) }),
            decision: decision,
            scores: scores
        )
    }

    static func scanned(_ id: String, at seconds: Double?, size: Int64 = 1000, modified: Date = start) -> ScannedPhoto {
        ScannedPhoto(
            file: file(id, size: size, modified: modified),
            metadata: PhotoMetadata(captureDate: seconds.map { start.addingTimeInterval($0) })
        )
    }

    /// Scores that raise no flag under the default tuning, adjusted by the arguments.
    static func scores(
        openness: Double? = nil,
        sharpness: Double = 90,
        highlights: Double = 0,
        shadows: Double = 0,
        aesthetics: Double? = 0.6,
        utility: Bool? = nil,
        horizon: Double? = nil,
        smudge: Double? = nil,
        faceCut: Bool = false,
        feature: [Float]? = nil
    ) -> PhotoScores {
        var scores = PhotoScores(analysedWidth: 1000, analysedHeight: 800)
        if openness != nil || faceCut {
            scores.faces = [
                FaceScores(
                    box: faceCut ? UnitRect(x: 0, y: 0.4, width: 0.2, height: 0.2) : UnitRect(x: 0.4, y: 0.4, width: 0.2, height: 0.2),
                    sizeFraction: 0.3,
                    leftEyeOpenness: openness,
                    rightEyeOpenness: openness,
                    sharpness: sharpness,
                    isCutByEdge: faceCut
                ),
            ]
        }
        scores.subjectSharpness = sharpness
        scores.clippedHighlights = highlights
        scores.clippedShadows = shadows
        scores.aesthetics = aesthetics
        scores.isUtility = utility
        scores.horizonDegrees = horizon
        scores.smudgeConfidence = smudge
        scores.featurePrint = feature.map(FeatureVector.encode)
        return scores
    }
}
